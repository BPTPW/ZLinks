//
//  CameraConnectionService.swift
//  ZLinks
//

import Foundation
import Network
import Combine

@MainActor
final class CameraConnectionService: ObservableObject {
    enum State: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    struct CameraInfo: Equatable {
        var manufacturer: String
        var model: String
        var serialNumber: String

        static let unavailable = CameraInfo(
            manufacturer: "Nikon",
            model: "等待读取",
            serialNumber: ""
        )
    }

    struct CameraStatus: Equatable {
        var batteryLevel: Int?
        var storageName: String?
        var storageTotalBytes: UInt64?
        var storageFreeBytes: UInt64?
        var mediaObjectCount: Int?
    }

    @Published private(set) var state: State = .disconnected
    @Published private(set) var cameraInfo: CameraInfo?
    @Published private(set) var connectedHost: String?
    @Published private(set) var cameraStatus = CameraStatus()
    @Published private(set) var debugLog = ""

    private var commandConnection: NWConnection?
    private var eventConnection: NWConnection?
    private var connectionNumber: UInt32?
    private var transactionID: UInt32 = 0

    func connect(host: String) async {
        await connect(endpoint: .hostPort(host: .init(host), port: 15740), displayHost: host)
    }

    func connect(endpoint: NWEndpoint, displayHost: String) async {
        appendLog("开始连接 endpoint=\(displayHost):15740")
        disconnect()
        state = .connecting

        do {
            let command = NWConnection(to: endpoint, using: .tcp)
            commandConnection = command
            appendLog("[command] 创建 TCP 连接")
            try await start(command)
            appendLog("[command] TCP 已就绪")

            let guid = Data([
                0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
                0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
            ])
            try await send(ptpIPPacket(type: .initCommandRequest, payload: initCommandPayload(guid: guid)), on: command)
            let acknowledgement = try await receivePacket(on: command)
            guard acknowledgement.type == PTPIPPacketType.initCommandAck.rawValue else {
                appendLog("[command] InitCommandAck 失败 expected=InitCommandAck actual=\(acknowledgement.typeName) payload=\(acknowledgement.payload.hexDump)")
                if acknowledgement.type == PTPIPPacketType.initFail.rawValue, acknowledgement.payload.count >= 4 {
                    throw CameraConnectionError.initFailed(acknowledgement.payload.uint32(at: 0))
                }
                throw CameraConnectionError.unexpectedPacket
            }

            let initResult = try parseInitCommandAck(acknowledgement.payload)
            connectionNumber = initResult.connectionNumber
            appendLog("[command] InitCommandAck connectionNumber=\(initResult.connectionNumber), name=\(initResult.name.debugDescription)")

            let event = NWConnection(to: endpoint, using: .tcp)
            eventConnection = event
            appendLog("[event] 创建 TCP 连接")
            try await start(event)
            appendLog("[event] TCP 已就绪")
            try await send(ptpIPPacket(type: .initEventRequest, payload: uint32Data(initResult.connectionNumber)), on: event)

            let eventAcknowledgement = try await receivePacket(on: event)
            guard eventAcknowledgement.type == PTPIPPacketType.initEventAck.rawValue else {
                appendLog("[event] InitEventAck 失败 expected=InitEventAck actual=\(eventAcknowledgement.typeName) payload=\(eventAcknowledgement.payload.hexDump)")
                if eventAcknowledgement.type == PTPIPPacketType.initFail.rawValue, eventAcknowledgement.payload.count >= 4 {
                    throw CameraConnectionError.initFailed(eventAcknowledgement.payload.uint32(at: 0))
                }
                throw CameraConnectionError.unexpectedPacket
            }

            transactionID = 0
            let sessionID: UInt32 = 1
            let openSessionResponse = try await operation(
                .openSession,
                parameters: [sessionID],
                dataPhase: nil,
                on: command
            )
            guard openSessionResponse.code == .ok else {
                throw CameraConnectionError.ptpResponse(openSessionResponse.code)
            }

            let deviceInfoResponse = try await operation(
                .getDeviceInfo,
                parameters: [],
                dataPhase: .receive,
                on: command
            )
            guard deviceInfoResponse.code == .ok, let deviceInfo = deviceInfoResponse.data else {
                throw CameraConnectionError.ptpResponse(deviceInfoResponse.code)
            }

            cameraInfo = try parseDeviceInfo(deviceInfo)
            appendLog("DeviceInfo 解析成功 manufacturer=\(cameraInfo?.manufacturer ?? ""), model=\(cameraInfo?.model ?? ""), serial=\(cameraInfo?.serialNumber ?? "")")
            cameraStatus = await readCameraStatus(on: command)
            connectedHost = displayHost
            state = .connected
            appendLog("连接成功")
        } catch {
            appendLog("连接失败 error=\(String(reflecting: error)) description=\(error.localizedDescription)")
            disconnectConnections()
            state = .failed(error.localizedDescription)
        }
    }

    func disconnect() {
        disconnectConnections()
        cameraInfo = nil
        connectedHost = nil
        cameraStatus = CameraStatus()
        state = .disconnected
    }

    func refreshCameraStatus() async {
        guard case .connected = state, let commandConnection else { return }
        appendLog("开始刷新相机状态")
        cameraStatus = await readCameraStatus(on: commandConnection)
    }

    func clearDebugLog() {
        debugLog = ""
    }

    private func operation(
        _ code: PTPOperationCode,
        parameters: [UInt32],
        dataPhase: DataPhase?,
        on connection: NWConnection
    ) async throws -> PTPResponse {
        let currentTransactionID = max(transactionID &+ 1, 1)
        transactionID = currentTransactionID

        var operationPayload = Data()
        let dataPhaseValue: UInt32
        switch dataPhase {
        case nil:
            dataPhaseValue = 0x00000001
        case .receive:
            dataPhaseValue = 0x00000001
        }
        operationPayload.append(uint32Data(dataPhaseValue))
        operationPayload.append(uint16Data(code.rawValue))
        operationPayload.append(uint32Data(currentTransactionID))
        for parameter in parameters {
            operationPayload.append(uint32Data(parameter))
        }
        appendLog("[command] OperationRequest name=\(code.debugName) code=0x\(String(format: "%04X", code.rawValue)) transaction=\(currentTransactionID) parameters=\(parameters.map { String(format: "0x%08X", $0) }.joined(separator: ","))")
        try await send(ptpIPPacket(type: .operationRequest, payload: operationPayload), on: connection)

        var receivedData = Data()
        while true {
            let packet = try await receivePacket(on: connection)
            switch packet.type {
            case PTPIPPacketType.startData.rawValue:
                guard packet.payload.count >= 12 else {
                    throw CameraConnectionError.malformedPacket
                }
                let dataTransactionID = packet.payload.uint32(at: 0)
                guard dataTransactionID == currentTransactionID else {
                    throw CameraConnectionError.transactionMismatch
                }
                continue
            case PTPIPPacketType.data.rawValue:
                guard packet.payload.count >= 4 else {
                    throw CameraConnectionError.malformedPacket
                }
                guard packet.payload.uint32(at: 0) == currentTransactionID else {
                    throw CameraConnectionError.transactionMismatch
                }
                receivedData.append(packet.payload.dropFirst(4))
            case PTPIPPacketType.endData.rawValue:
                guard packet.payload.count >= 4 else {
                    throw CameraConnectionError.malformedPacket
                }
                guard packet.payload.uint32(at: 0) == currentTransactionID else {
                    throw CameraConnectionError.transactionMismatch
                }
                receivedData.append(packet.payload.dropFirst(4))
            case PTPIPPacketType.operationResponse.rawValue:
                guard packet.payload.count >= 6 else {
                    throw CameraConnectionError.malformedPacket
                }
                let responseCode = packet.payload.uint16(at: 0)
                let responseTransactionID = packet.payload.uint32(at: 2)
                guard responseTransactionID == currentTransactionID else {
                    appendLog("[command] 事务号不匹配 expected=\(currentTransactionID) actual=\(responseTransactionID)")
                    throw CameraConnectionError.transactionMismatch
                }
                appendLog("[command] OperationResponse name=\(code.debugName) code=0x\(String(format: "%04X", responseCode)) transaction=\(responseTransactionID) dataBytes=\(receivedData.count)")
                return PTPResponse(code: responseCode, data: dataPhase == .receive ? receivedData : nil)
            default:
                appendLog("[command] 忽略未预期包 type=\(packet.typeName)")
                continue
            }
        }
    }

    private func start(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    Task { @MainActor in self.appendLog("NWConnection state=ready") }
                    connection.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error):
                    Task { @MainActor in self.appendLog("NWConnection state=failed error=\(String(reflecting: error))") }
                    connection.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                case .cancelled:
                    Task { @MainActor in self.appendLog("NWConnection state=cancelled") }
                    connection.stateUpdateHandler = nil
                    continuation.resume(throwing: CameraConnectionError.connectionCancelled)
                default:
                    break
                }
            }
            connection.start(queue: .main)
        }
    }

    private func send(_ packet: Data, on connection: NWConnection) async throws {
        appendLog("发送 PTP/IP type=\(packet.packetTypeName) totalBytes=\(packet.count) hex=\(packet.hexDump)")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: packet, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func receivePacket(on connection: NWConnection) async throws -> PTPIPPacket {
        let header = try await receiveExactly(8, on: connection)
        let totalLength = Int(header.uint32(at: 0))
        guard totalLength >= 8 else {
            appendLog("接收报文长度非法 totalLength=\(totalLength) header=\(header.hexDump)")
            throw CameraConnectionError.malformedPacket
        }
        let type = header.uint32(at: 4)
        let payload = totalLength > 8 ? try await receiveExactly(totalLength - 8, on: connection) : Data()
        let packet = PTPIPPacket(type: type, payload: payload)
        appendLog("接收 PTP/IP type=\(packet.typeName) totalBytes=\(totalLength) payloadBytes=\(payload.count) hex=\(packet.hexDump)")
        return packet
    }

    private func receiveExactly(_ count: Int, on connection: NWConnection) async throws -> Data {
        var collected = Data()
        while collected.count < count {
            let remaining = count - collected.count
            let chunk = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, isComplete, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let data, !data.isEmpty {
                        continuation.resume(returning: data)
                    } else if isComplete {
                        continuation.resume(throwing: CameraConnectionError.connectionCancelled)
                    }
                }
            }
            collected.append(chunk)
        }
        return collected
    }

    private func disconnectConnections() {
        commandConnection?.cancel()
        eventConnection?.cancel()
        commandConnection = nil
        eventConnection = nil
        connectionNumber = nil
    }

    private func readCameraStatus(on connection: NWConnection) async -> CameraStatus {
        var status = CameraStatus()

        // These are standard PTP properties. Nikon may omit one or expose a
        // model-specific value, so status probing must never break connection.
        if let battery = try? await operation(.getDevicePropValue, parameters: [0x5001], dataPhase: .receive, on: connection),
           battery.code == PTPResponseCode.ok.rawValue,
           let data = battery.data,
           let value = data.first {
            status.batteryLevel = min(Int(value), 100)
        }

        if let storageIDs = try? await operation(.getStorageIDs, parameters: [], dataPhase: .receive, on: connection),
           storageIDs.code == PTPResponseCode.ok.rawValue,
           let data = storageIDs.data,
           data.count >= 4 {
            let count = Int(data.uint32(at: 0))
            if count > 0, data.count >= 8 {
                let storageID = data.uint32(at: 4)
                if let storageInfo = try? await operation(.getStorageInfo, parameters: [storageID], dataPhase: .receive, on: connection),
                   storageInfo.code == PTPResponseCode.ok.rawValue,
                   let storageData = storageInfo.data,
                   storageData.count >= 27 {
                    status.storageTotalBytes = storageData.uint64(at: 6)
                    status.storageFreeBytes = storageData.uint64(at: 14)
                    status.storageName = try? readPTPString(from: storageData, offset: 26).value
                }
                if let numberOfObjects = try? await operation(
                    .getNumObjects,
                    parameters: [storageID, 0, 0],
                    dataPhase: .receive,
                    on: connection
                ), numberOfObjects.code == PTPResponseCode.ok.rawValue,
                   let objectData = numberOfObjects.data,
                   objectData.count >= 4 {
                    status.mediaObjectCount = Int(objectData.uint32(at: 0))
                }
            }
        }

        return status
    }

    private func initCommandPayload(guid: Data) -> Data {
        var payload = Data(guid.prefix(16))
        if payload.count < 16 {
            payload.append(Data(repeating: 0, count: 16 - payload.count))
        }
        payload.append(utf16NullTerminatedString("ZLinks iOS"))
        payload.append(uint32Data(0x00010000))
        return payload
    }

    private func parseInitCommandAck(_ data: Data) throws -> (connectionNumber: UInt32, name: String) {
        guard data.count >= 24 else {
            throw CameraConnectionError.malformedPacket
        }
        let connectionNumber = data.uint32(at: 0)
        let protocolVersionOffset = data.count - 4
        guard protocolVersionOffset >= 20, protocolVersionOffset % 2 == 0 else {
            throw CameraConnectionError.malformedPacket
        }

        var nameEnd = 20
        while nameEnd + 1 < protocolVersionOffset {
            if data.uint16(at: nameEnd) == 0 {
                break
            }
            nameEnd += 2
        }
        guard nameEnd + 1 < protocolVersionOffset,
              data.uint16(at: nameEnd) == 0 else {
            appendLog("InitCommandAck FriendlyName 未找到 UTF-16 终止符 start=20 end=\(protocolVersionOffset)")
            throw CameraConnectionError.malformedPacket
        }

        let nameData = data[20..<nameEnd]
        let name = String(data: nameData, encoding: .utf16LittleEndian) ?? ""
        let protocolVersion = data.uint32(at: protocolVersionOffset)
        appendLog("InitCommandAck FriendlyName=\(name.debugDescription) protocolVersion=0x\(String(format: "%08X", protocolVersion))")
        return (connectionNumber, name)
    }

    private func parseDeviceInfo(_ data: Data) throws -> CameraInfo {
        appendLog("开始解析 DeviceInfo bytes=\(data.count) hex=\(data.hexDump)")
        guard data.count >= 8 else {
            throw CameraConnectionError.malformedPacket
        }

        // FunctionalMode follows the variable-length vendor extension string.
        // Nikon Z5 returns the standard field order with this placement.
        return try parseDeviceInfoFields(data)
    }

    private func parseDeviceInfoFields(_ data: Data) throws -> CameraInfo {
        var offset = 8 // StandardVersion, VendorExtensionID, VendorExtensionVersion
        offset = try skipPTPString(in: data, at: offset)
        appendLog("DeviceInfo VendorExtension offset=\(offset)")
        guard data.count >= offset + 2 else {
            throw CameraConnectionError.malformedPacket
        }
        let functionalMode = data.uint16(at: offset)
        appendLog("DeviceInfo FunctionalMode=0x\(String(format: "%04X", functionalMode)) offset=\(offset)")
        offset += 2
        offset = try skipUInt16Array(in: data, at: offset)
        appendLog("DeviceInfo Operations offset=\(offset)")
        offset = try skipUInt16Array(in: data, at: offset)
        appendLog("DeviceInfo Events offset=\(offset)")
        offset = try skipUInt16Array(in: data, at: offset)
        appendLog("DeviceInfo DeviceProperties offset=\(offset)")
        offset = try skipUInt16Array(in: data, at: offset)
        appendLog("DeviceInfo CaptureFormats offset=\(offset)")
        offset = try skipUInt16Array(in: data, at: offset)
        appendLog("DeviceInfo ImageFormats offset=\(offset)")

        let manufacturer = try readPTPString(from: data, offset: offset)
        let model = try readPTPString(from: data, offset: manufacturer.nextOffset)
        let version = try readPTPString(from: data, offset: model.nextOffset)
        let serial = try readPTPString(from: data, offset: version.nextOffset)
        appendLog("DeviceInfo 字段 manufacturerOffset=\(offset) modelOffset=\(manufacturer.nextOffset) versionOffset=\(model.nextOffset) serialOffset=\(version.nextOffset) end=\(serial.nextOffset)")

        return CameraInfo(
            manufacturer: manufacturer.value.isEmpty ? "Nikon" : manufacturer.value,
            model: model.value.isEmpty ? "未知型号" : model.value,
            serialNumber: serial.value
        )
    }

    private func skipUInt16Array(in data: Data, at offset: Int) throws -> Int {
        guard data.count >= offset + 4 else {
            throw CameraConnectionError.malformedPacket
        }
        let count = Int(data.uint32(at: offset))
        let nextOffset = offset + 4 + count * 2
        guard nextOffset <= data.count else {
            throw CameraConnectionError.malformedPacket
        }
        return nextOffset
    }

    private func skipPTPString(in data: Data, at offset: Int) throws -> Int {
        try readPTPString(from: data, offset: offset).nextOffset
    }

    private func readPTPString(from data: Data, offset: Int) throws -> (value: String, nextOffset: Int) {
        guard offset < data.count else {
            appendLog("PTP 字符串偏移越界 offset=\(offset) dataBytes=\(data.count)")
            throw CameraConnectionError.malformedPacket
        }
        let characterCount = Int(data[offset])
        guard characterCount > 0 else {
            return ("", offset + 1)
        }
        let byteCount = characterCount * 2
        let end = offset + 1 + byteCount
        guard end <= data.count else {
            appendLog("PTP 字符串长度越界 offset=\(offset) characterCount=\(characterCount) end=\(end) dataBytes=\(data.count)")
            throw CameraConnectionError.malformedPacket
        }
        let stringData = data[(offset + 1)..<(end - 2)]
        let value = String(data: stringData, encoding: .utf16LittleEndian) ?? ""
        return (value, end)
    }

    private func appendLog(_ message: String) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let line = "[\(formatter.string(from: Date()))] \(message)"
        if debugLog.isEmpty {
            debugLog = line
        } else {
            debugLog += "\n" + line
        }
    }
}

private enum DataPhase {
    case receive
}

private struct PTPResponse {
    let code: UInt16
    let data: Data?
}

private struct PTPIPPacket {
    let type: UInt32
    let payload: Data

    var typeName: String { PTPIPPacketType(rawValue: type)?.debugName ?? String(format: "0x%08X", type) }
    var hexDump: String { uint32Data(UInt32(payload.count + 8)).hexDump + " " + uint32Data(type).hexDump + (payload.isEmpty ? "" : " " + payload.hexDump) }
}

private enum PTPIPPacketType: UInt32 {
    case initCommandRequest = 0x00000001
    case initCommandAck = 0x00000002
    case initEventRequest = 0x00000003
    case initEventAck = 0x00000004
    case initFail = 0x00000005
    case operationRequest = 0x00000006
    case operationResponse = 0x00000007
    case event = 0x00000008
    case startData = 0x00000009
    case data = 0x0000000A
    case endData = 0x0000000C

    var debugName: String {
        switch self {
        case .initCommandRequest: return "InitCommandRequest"
        case .initCommandAck: return "InitCommandAck"
        case .initEventRequest: return "InitEventRequest"
        case .initEventAck: return "InitEventAck"
        case .initFail: return "InitFail"
        case .operationRequest: return "OperationRequest"
        case .operationResponse: return "OperationResponse"
        case .event: return "Event"
        case .startData: return "StartData"
        case .data: return "Data"
        case .endData: return "EndData"
        }
    }
}

private enum PTPOperationCode: UInt16 {
    case getDeviceInfo = 0x1001
    case openSession = 0x1002
    case getStorageIDs = 0x1004
    case getStorageInfo = 0x1005
    case getNumObjects = 0x1006
    case getDevicePropValue = 0x1015

    var debugName: String {
        switch self {
        case .getDeviceInfo: return "GetDeviceInfo"
        case .openSession: return "OpenSession"
        case .getStorageIDs: return "GetStorageIDs"
        case .getStorageInfo: return "GetStorageInfo"
        case .getNumObjects: return "GetNumObjects"
        case .getDevicePropValue: return "GetDevicePropValue"
        }
    }
}

private enum PTPResponseCode: UInt16 {
    case ok = 0x2001
}

private extension UInt16 {
    static let ok = PTPResponseCode.ok.rawValue
}

private enum CameraConnectionError: LocalizedError {
    case connectionCancelled
    case malformedPacket
    case unexpectedPacket
    case transactionMismatch
    case ptpResponse(UInt16)
    case initFailed(UInt32)

    var errorDescription: String? {
        switch self {
        case .connectionCancelled:
            return "与相机的连接已关闭。"
        case .malformedPacket:
            return "相机返回了无法识别的数据。"
        case .unexpectedPacket:
            return "相机未完成 PTP/IP 初始化。"
        case .transactionMismatch:
            return "相机响应与当前请求不匹配。"
        case .ptpResponse(let code):
            return String(format: "相机拒绝了请求（0x%04X）。", code)
        case .initFailed(let code):
            return String(format: "相机拒绝了 PTP/IP 初始化（失败码 0x%08X）。", code)
        }
    }
}

private func ptpIPPacket(type: PTPIPPacketType, payload: Data) -> Data {
    uint32Data(UInt32(payload.count + 8)) + uint32Data(type.rawValue) + payload
}

private func uint16Data(_ value: UInt16) -> Data {
    withUnsafeBytes(of: value.littleEndian) { Data($0) }
}

private func uint32Data(_ value: UInt32) -> Data {
    withUnsafeBytes(of: value.littleEndian) { Data($0) }
}

private func ptpString(_ string: String) -> Data {
    let utf16 = Array(string.utf16)
    var data = Data([UInt8(min(utf16.count + 1, Int(UInt8.max)))])
    for codeUnit in utf16.prefix(Int(UInt8.max) - 1) {
        data.append(uint16Data(codeUnit))
    }
    data.append(uint16Data(0))
    return data
}

private func utf16NullTerminatedString(_ string: String) -> Data {
    var data = Data()
    for codeUnit in string.utf16 {
        data.append(uint16Data(codeUnit))
    }
    data.append(uint16Data(0))
    return data
}

private extension Data {
    var hexDump: String {
        let limit = 4096
        let bytes = prefix(limit).map { String(format: "%02X", $0) }.joined(separator: " ")
        return count > limit ? "\(bytes) ... [truncated, total=\(count)]" : bytes
    }

    var packetTypeName: String {
        guard count >= 8 else { return "invalid-header" }
        return PTPIPPacketType(rawValue: uint32(at: 4))?.debugName ?? String(format: "0x%08X", uint32(at: 4))
    }

    func uint16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    func uint32(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
    }

    func uint64(at offset: Int) -> UInt64 {
        UInt64(uint32(at: offset)) | UInt64(uint32(at: offset + 4)) << 32
    }
}
