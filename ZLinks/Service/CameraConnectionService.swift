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

    private var commandConnection: NWConnection?
    private var eventConnection: NWConnection?
    private var connectionNumber: UInt32?
    private var transactionID: UInt32 = 0

    func connect(host: String) async {
        await connect(endpoint: .hostPort(host: .init(host), port: 15740), displayHost: host)
    }

    func connect(endpoint: NWEndpoint, displayHost: String) async {
        disconnect()
        state = .connecting

        do {
            let command = NWConnection(to: endpoint, using: .tcp)
            commandConnection = command
            try await start(command)

            let guid = UUID().uuidString.data(using: .utf8) ?? Data()
            try await send(ptpIPPacket(type: .initCommandRequest, payload: initCommandPayload(guid: guid)), on: command)
            let acknowledgement = try await receivePacket(on: command)
            guard acknowledgement.type == PTPIPPacketType.initCommandAck.rawValue else {
                throw CameraConnectionError.unexpectedPacket
            }

            let initResult = try parseInitCommandAck(acknowledgement.payload)
            connectionNumber = initResult.connectionNumber

            let event = NWConnection(to: endpoint, using: .tcp)
            eventConnection = event
            try await start(event)
            try await send(ptpIPPacket(type: .initEventRequest, payload: uint32Data(initResult.connectionNumber)), on: event)

            let eventAcknowledgement = try await receivePacket(on: event)
            guard eventAcknowledgement.type == PTPIPPacketType.initEventAck.rawValue else {
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
            cameraStatus = await readCameraStatus(on: command)
            connectedHost = displayHost
            state = .connected
        } catch {
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
        cameraStatus = await readCameraStatus(on: commandConnection)
    }

    private func operation(
        _ code: PTPOperationCode,
        parameters: [UInt32],
        dataPhase: DataPhase?,
        on connection: NWConnection
    ) async throws -> PTPResponse {
        transactionID &+= 1
        let currentTransactionID = transactionID

        var operationPayload = Data()
        operationPayload.append(uint16Data(code.rawValue))
        operationPayload.append(uint32Data(currentTransactionID))
        for parameter in parameters {
            operationPayload.append(uint32Data(parameter))
        }
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
                    throw CameraConnectionError.transactionMismatch
                }
                return PTPResponse(code: responseCode, data: dataPhase == .receive ? receivedData : nil)
            default:
                continue
            }
        }
    }

    private func start(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error):
                    connection.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                case .cancelled:
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
            throw CameraConnectionError.malformedPacket
        }
        let type = header.uint32(at: 4)
        let payload = totalLength > 8 ? try await receiveExactly(totalLength - 8, on: connection) : Data()
        return PTPIPPacket(type: type, payload: payload)
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
        payload.append(ptpString("ZLinks iOS"))
        payload.append(uint32Data(1))
        return payload
    }

    private func parseInitCommandAck(_ data: Data) throws -> (connectionNumber: UInt32, name: String) {
        guard data.count >= 21 else {
            throw CameraConnectionError.malformedPacket
        }
        let connectionNumber = data.uint32(at: 0)
        let name = try readPTPString(from: data, offset: 20).value
        return (connectionNumber, name)
    }

    private func parseDeviceInfo(_ data: Data) throws -> CameraInfo {
        var offset = 0
        guard data.count >= 8 else {
            throw CameraConnectionError.malformedPacket
        }
        offset += 8 // StandardVersion, VendorExtensionID, VendorExtensionVersion
        offset = try skipPTPString(in: data, at: offset)
        offset = try skipUInt16Array(in: data, at: offset)
        offset = try skipUInt16Array(in: data, at: offset)
        offset = try skipUInt16Array(in: data, at: offset)
        offset = try skipUInt16Array(in: data, at: offset)
        offset = try skipUInt16Array(in: data, at: offset)

        let manufacturer = try readPTPString(from: data, offset: offset)
        let model = try readPTPString(from: data, offset: manufacturer.nextOffset)
        let version = try readPTPString(from: data, offset: model.nextOffset)
        let serial = try readPTPString(from: data, offset: version.nextOffset)

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
            throw CameraConnectionError.malformedPacket
        }
        let characterCount = Int(data[offset])
        guard characterCount > 0 else {
            return ("", offset + 1)
        }
        let byteCount = characterCount * 2
        let end = offset + 1 + byteCount
        guard end <= data.count else {
            throw CameraConnectionError.malformedPacket
        }
        let stringData = data[(offset + 1)..<(end - 2)]
        let value = String(data: stringData, encoding: .utf16LittleEndian) ?? ""
        return (value, end)
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
}

private enum PTPIPPacketType: UInt32 {
    case initCommandRequest = 0x00000001
    case initCommandAck = 0x00000002
    case initEventRequest = 0x00000003
    case initEventAck = 0x00000004
    case operationRequest = 0x00000006
    case operationResponse = 0x00000007
    case event = 0x00000008
    case startData = 0x00000009
    case data = 0x0000000A
    case endData = 0x0000000C
}

private enum PTPOperationCode: UInt16 {
    case getDeviceInfo = 0x1001
    case openSession = 0x1002
    case getStorageIDs = 0x1004
    case getStorageInfo = 0x1005
    case getNumObjects = 0x1006
    case getDevicePropValue = 0x1015
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

private extension Data {
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
