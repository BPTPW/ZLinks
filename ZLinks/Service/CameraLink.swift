//
//  CameraLink.swift
//  ZLinks
//
//  Shared PTP/IP wire format plus the transport channels that carry it.
//  Wi-Fi uses PTP/IP over TCP. USB reuses the exact same packet format on top
//  of ImageCaptureCore's PTP passthrough, so the camera protocol layer above
//  this file never needs to know which cable is in use.
//

import Foundation
import Network

/// How the app is currently talking to the camera.
enum CameraLinkKind: String, Equatable, Sendable {
    case wifi
    case usb

    var title: String {
        switch self {
        case .wifi: return "WI-FI"
        case .usb: return "USB 有线"
        }
    }

    var symbolName: String {
        switch self {
        case .wifi: return "wifi"
        case .usb: return "cable.connector"
        }
    }
}

/// A duplex channel carrying framed PTP/IP packets.
///
/// The camera protocol layer (`CameraConnectionService.operation`) only talks to
/// this interface, so one implementation carries the bytes over TCP and another
/// carries them over the USB PTP pipe.
@MainActor
protocol PTPChannel: AnyObject {
    var isReady: Bool { get }
    var linkName: String { get }
    func send(packet: Data) async throws
    func receivePacket() async throws -> PTPIPPacket
    func close()
}

/// PTP/IP over TCP (the Wi-Fi transport).
///
/// Owns both the command and event sockets plus the PTP/IP handshake that turns
/// a raw TCP endpoint into a usable camera session.
@MainActor
final class PTPIPTCPChannel: PTPChannel {
    private let endpoint: NWEndpoint
    private var command: NWConnection?
    private var event: NWConnection?
    private var eventTask: Task<Void, Never>?

    /// Reported back to `CameraConnectionService` so it can reconnect.
    var failureHandler: ((String) -> Void)?
    var logHandler: ((String) -> Void)?
    var eventHandler: ((PTPEvent) -> Void)?

    private(set) var connectionNumber: UInt32?

    init(endpoint: NWEndpoint) {
        self.endpoint = endpoint
    }

    var isReady: Bool { command?.state == .ready }

    var linkName: String { "PTP/IP" }

    func open() async throws {
        let command = NWConnection(to: endpoint, using: .tcp)
        self.command = command
        logHandler?("[command] 创建 TCP 连接")
        try await start(command, label: "command")
        logHandler?("[command] TCP 已就绪")

        let guid = Data([
            0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
            0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff
        ])
        try await sendOnConnection(
            ptpIPPacket(type: .initCommandRequest, payload: initCommandPayload(guid: guid)),
            on: command
        )
        let acknowledgement = try await receivePacket(on: command)
        guard acknowledgement.type == PTPIPPacketType.initCommandAck.rawValue else {
            logHandler?(
                "[command] InitCommandAck 失败 expected=InitCommandAck actual=\(acknowledgement.typeName) " +
                    "payload=\(acknowledgement.payload.hexDump)"
            )
            if acknowledgement.type == PTPIPPacketType.initFail.rawValue, acknowledgement.payload.count >= 4 {
                throw CameraConnectionError.initFailed(acknowledgement.payload.uint32(at: 0))
            }
            throw CameraConnectionError.unexpectedPacket
        }

        let initResult = try parseInitCommandAck(acknowledgement.payload)
        connectionNumber = initResult.connectionNumber
        logHandler?(
            "[command] InitCommandAck connectionNumber=\(initResult.connectionNumber), name=\(initResult.name.debugDescription)"
        )

        let event = NWConnection(to: endpoint, using: .tcp)
        self.event = event
        logHandler?("[event] 创建 TCP 连接")
        try await start(event, label: "event")
        logHandler?("[event] TCP 已就绪")
        try await sendOnConnection(
            ptpIPPacket(type: .initEventRequest, payload: uint32Data(initResult.connectionNumber)),
            on: event
        )

        let eventAcknowledgement = try await receivePacket(on: event)
        guard eventAcknowledgement.type == PTPIPPacketType.initEventAck.rawValue else {
            logHandler?(
                "[event] InitEventAck 失败 expected=InitEventAck actual=\(eventAcknowledgement.typeName) " +
                    "payload=\(eventAcknowledgement.payload.hexDump)"
            )
            if eventAcknowledgement.type == PTPIPPacketType.initFail.rawValue,
               eventAcknowledgement.payload.count >= 4
            {
                throw CameraConnectionError.initFailed(eventAcknowledgement.payload.uint32(at: 0))
            }
            throw CameraConnectionError.unexpectedPacket
        }
        logHandler?("[event] InitEventAck，开始监听相机事件")
        startEventLoop(on: event)
    }

    func send(packet: Data) async throws {
        guard let command else { throw CameraConnectionError.connectionCancelled }
        try await sendOnConnection(packet, on: command)
    }

    func receivePacket() async throws -> PTPIPPacket {
        guard let command else { throw CameraConnectionError.connectionCancelled }
        return try await receivePacket(on: command)
    }

    func close() {
        failureHandler = nil
        eventHandler = nil
        eventTask?.cancel()
        eventTask = nil
        command?.stateUpdateHandler = nil
        event?.stateUpdateHandler = nil
        command?.cancel()
        event?.cancel()
        command = nil
        event = nil
        connectionNumber = nil
    }

    private func startEventLoop(on connection: NWConnection) {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            guard let self else { return }
            do {
                while !Task.isCancelled {
                    let packet = try await self.receivePacket(on: connection)
                    guard packet.type == PTPIPPacketType.event.rawValue else {
                        self.logHandler?(
                            "[event] 忽略非事件报文 type=\(packet.typeName) payload=\(packet.payload.hexDump)"
                        )
                        continue
                    }
                    let event = try PTPEvent(payload: packet.payload)
                    let parameters = event.parameters
                        .map { String(format: "0x%08X", $0) }
                        .joined(separator: ",")
                    self.logHandler?(
                        "[event] 收到 \(event.debugName) transaction=\(event.transactionID) params=[\(parameters)]"
                    )
                    self.eventHandler?(event)
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.logHandler?("[event] 监听失败 error=\(error.localizedDescription)")
                self.failureHandler?("Event Connection 已断开：\(error.localizedDescription)")
            }
        }
    }

    // MARK: - Socket helpers

    private func start(_ connection: NWConnection, label: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    Task { @MainActor in
                        self?.logHandler?("NWConnection[\(label)] state=ready")
                    }
                    connection.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error):
                    Task { @MainActor in
                        self?.logHandler?("NWConnection[\(label)] state=failed error=\(String(reflecting: error))")
                        self?.failureHandler?(error.localizedDescription)
                    }
                    connection.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                case .cancelled:
                    Task { @MainActor in
                        self?.logHandler?("NWConnection[\(label)] state=cancelled")
                        self?.failureHandler?("连接已取消")
                    }
                    connection.stateUpdateHandler = nil
                    continuation.resume(throwing: CameraConnectionError.connectionCancelled)
                default:
                    break
                }
            }
            connection.start(queue: .main)
        }
        monitor(connection, label: label)
    }

    private func monitor(_ connection: NWConnection, label: String) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error):
                Task { @MainActor in
                    self?.logHandler?("NWConnection[\(label)] state=failed error=\(String(reflecting: error))")
                    self?.failureHandler?(error.localizedDescription)
                }
            case .cancelled:
                Task { @MainActor in
                    self?.logHandler?("NWConnection[\(label)] state=cancelled")
                    self?.failureHandler?("连接已取消")
                }
            default:
                break
            }
        }
    }

    private func sendOnConnection(_ packet: Data, on connection: NWConnection) async throws {
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: packet, completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                })
            }
        } catch {
            failureHandler?(error.localizedDescription)
            throw error
        }
    }

    private func receivePacket(on connection: NWConnection) async throws -> PTPIPPacket {
        let header = try await receiveExactly(8, on: connection)
        let totalLength = Int(header.uint32(at: 0))
        guard totalLength >= 8 else {
            logHandler?("接收报文长度非法 totalLength=\(totalLength) header=\(header.hexDump)")
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
            let chunk: Data
            do {
                chunk = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
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
            } catch {
                failureHandler?(error.localizedDescription)
                throw error
            }
            collected.append(chunk)
        }
        return collected
    }

    // MARK: - PTP/IP handshake

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
              data.uint16(at: nameEnd) == 0
        else {
            logHandler?("InitCommandAck FriendlyName 未找到 UTF-16 终止符 start=20 end=\(protocolVersionOffset)")
            throw CameraConnectionError.malformedPacket
        }

        let nameData = data[20..<nameEnd]
        let name = String(data: nameData, encoding: .utf16LittleEndian) ?? ""
        let protocolVersion = data.uint32(at: protocolVersionOffset)
        logHandler?(
            "InitCommandAck FriendlyName=\(name.debugDescription) protocolVersion=0x\(String(format: "%08X", protocolVersion))"
        )
        return (connectionNumber, name)
    }
}

// MARK: - PTP/IP packet framing

struct PTPIPPacket {
    let type: UInt32
    let payload: Data

    init(type: UInt32, payload: Data) {
        self.type = type
        self.payload = payload
    }

    var typeName: String { PTPIPPacketType(rawValue: type)?.debugName ?? String(format: "0x%08X", type) }
    var hexDump: String {
        uint32Data(UInt32(payload.count + 8)).hexDump + " " + uint32Data(type).hexDump +
            (payload.isEmpty ? "" : " " + payload.hexDump)
    }
}

struct PTPEvent: Equatable, Sendable {
    let code: UInt16
    let transactionID: UInt32
    let parameters: [UInt32]

    init(payload: Data) throws {
        guard payload.count >= 6, (payload.count - 6).isMultiple(of: 4) else {
            throw CameraConnectionError.malformedPacket
        }
        code = payload.uint16(at: 0)
        transactionID = payload.uint32(at: 2)
        parameters = stride(from: 6, to: payload.count, by: 4).map {
            payload.uint32(at: $0)
        }
    }

    var debugName: String {
        PTPEventCode(rawValue: code)?.debugName ?? String(format: "Event(0x%04X)", code)
    }
}

enum PTPEventCode: UInt16 {
    case objectAdded = 0x4002
    case objectRemoved = 0x4003
    case devicePropChanged = 0x4006

    var debugName: String {
        switch self {
        case .objectAdded: return "ObjectAdded"
        case .objectRemoved: return "ObjectRemoved"
        case .devicePropChanged: return "DevicePropChanged"
        }
    }
}

enum PTPIPPacketType: UInt32 {
    case initCommandRequest = 0x00000001
    case initCommandAck = 0x00000002
    case initEventRequest = 0x00000003
    case initEventAck = 0x00000004
    case initFail = 0x00000005
    case operationRequest = 0x00000006
    case operationResponse = 0x00000007
    case event = 0x00000008
    case startData = 0x00000009
    case data = 0x0000000a
    case cancelTransaction = 0x0000000b
    case endData = 0x0000000c

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
        case .cancelTransaction: return "CancelTransaction"
        case .endData: return "EndData"
        }
    }
}

enum PTPResponseCode: UInt16 {
    case ok = 0x2001
    case operationNotSupported = 0x2006
    case sessionAlreadyOpen = 0x201e
    case deviceBusy = 0x2019
    case invalidParameter = 0x201d
    case nikonOutOfFocus = 0xa002
}

extension UInt16 {
    static let ok = PTPResponseCode.ok.rawValue
}

enum CameraConnectionError: LocalizedError {
    case connectionCancelled
    case malformedPacket
    case unexpectedPacket
    case transactionMismatch
    case ptpResponse(UInt16)
    case initFailed(UInt32)
    case usbUnavailable(String)

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
            switch code {
            case 0x200a:
                return "当前相机或拍摄模式不支持该参数。"
            case 0x2019:
                return "相机正忙，请稍后重试。"
            case 0x201a:
                return "相机拒绝修改该参数。"
            default:
                return String(format: "相机拒绝了请求（0x%04X）。", code)
            }
        case .initFailed(let code):
            return String(format: "相机拒绝了 PTP/IP 初始化（失败码 0x%08X）。", code)
        case .usbUnavailable(let reason):
            return "USB 连接不可用：\(reason)"
        }
    }
}

func ptpIPPacket(type: PTPIPPacketType, payload: Data) -> Data {
    uint32Data(UInt32(payload.count + 8)) + uint32Data(type.rawValue) + payload
}

func uint16Data(_ value: UInt16) -> Data {
    withUnsafeBytes(of: value.littleEndian) { Data($0) }
}

func uint32Data(_ value: UInt32) -> Data {
    withUnsafeBytes(of: value.littleEndian) { Data($0) }
}

func utf16NullTerminatedString(_ string: String) -> Data {
    var data = Data()
    for codeUnit in string.utf16 {
        data.append(uint16Data(codeUnit))
    }
    data.append(uint16Data(0))
    return data
}

extension Data {
    var hexDump: String {
        let limit = 256
        let bytes = prefix(limit).map { String(format: "%02X", $0) }.joined(separator: " ")
        return count > limit ? "\(bytes) ... [truncated, total=\(count)]" : bytes
    }

    /// 仅用于日志：按 8 字节报文头判断 PTP/IP 包类型。
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
