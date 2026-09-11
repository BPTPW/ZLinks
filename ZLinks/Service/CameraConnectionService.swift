//
//  CameraConnectionService.swift
//  ZLinks
//

import Foundation
import Network
import Combine
import UIKit

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

    enum LensConnectionState: Equatable {
        case disconnected
        case connected
        case unknown
        case noneAttached

        var title: String {
            switch self {
            case .disconnected:
                return "未连接"
            case .connected:
                return "已连接"
            case .unknown:
                return "未知"
            case .noneAttached:
                return "未安装"
            }
        }
    }

    struct LensInfo: Equatable {
        var connectionState: LensConnectionState = .disconnected
        var lensID: UInt16?
        var lensType: UInt32?
        var minFocalLengthMM: Double?
        var maxFocalLengthMM: Double?
        var maxApertureAtMinFocal: Double?
        var maxApertureAtMaxFocal: Double?
        var currentFocalLengthMM: Double?
        var currentAperture: Double?

        static let disconnected = LensInfo()
    }

    struct GalleryItem: Identifiable, Equatable, Hashable {
        let id: UInt32
        var handle: UInt32 { id }
        var filename: String
        var objectFormat: UInt16
        var fileSize: UInt64
        var isVideo: Bool
        var captureDate: Date?
        var durationSeconds: Int?
    }

    struct GalleryDirectory: Identifiable, Equatable, Hashable {
        /// Stable ID for picker selection. Root synthetic directory uses 0.
        let id: UInt32
        var handle: UInt32 { id }
        let storageID: UInt32
        let name: String
        /// Display path like `DCIM/100NCZ_5` when available.
        let path: String
        /// True for the synthetic root entry used when media sits outside folders.
        let isSyntheticRoot: Bool

        var pickerTitle: String {
            if isSyntheticRoot { return name }
            if !path.isEmpty { return path }
            return name.isEmpty ? String(format: "0x%08X", handle) : name
        }
    }

    @Published private(set) var state: State = .disconnected
    @Published private(set) var cameraInfo: CameraInfo?
    @Published private(set) var connectedHost: String?
    @Published private(set) var cameraStatus = CameraStatus()
    @Published private(set) var lensInfo = LensInfo.disconnected
    @Published private(set) var galleryDirectories: [GalleryDirectory] = []
    @Published private(set) var selectedGalleryDirectoryID: UInt32?
    @Published private(set) var galleryItems: [GalleryItem] = []
    @Published private(set) var debugLog = ""

    private var commandConnection: NWConnection?
    private var eventConnection: NWConnection?
    private var connectionNumber: UInt32?
    private var transactionID: UInt32 = 0
    private var isOperationBusy = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []
    private var thumbnailCache: [UInt32: Data] = [:]
    private var objectImageCache: [UInt32: Data] = [:]
    private var durationCache: [UInt32: Int] = [:]

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
            lensInfo = await readLensInfo(on: command)
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
        lensInfo = .disconnected
        galleryItems = []
        galleryDirectories = []
        selectedGalleryDirectoryID = nil
        thumbnailCache = [:]
        objectImageCache = [:]
        durationCache = [:]
        state = .disconnected
    }

    func refreshCameraStatus() async {
        guard case .connected = state, let commandConnection else { return }
        appendLog("开始刷新相机状态")
        cameraStatus = await readCameraStatus(on: commandConnection)
        lensInfo = await readLensInfo(on: commandConnection)
    }

    /// Refresh directory list, keep/select a directory, then load that directory's media.
    func refreshGallery(selectingDirectoryID directoryID: UInt32? = nil) async {
        guard case .connected = state, let commandConnection else {
            galleryItems = []
            galleryDirectories = []
            selectedGalleryDirectoryID = nil
            appendLog("[图库] 未连接相机，跳过刷新")
            return
        }

        appendLog("[图库] 开始刷新目录列表")
        do {
            let directories = try await loadGalleryDirectories(on: commandConnection)
            galleryDirectories = directories
            appendLog("[图库] 目录列表完成 count=\(directories.count)")

            let preferred = directoryID ?? selectedGalleryDirectoryID
            let selected = directories.first(where: { $0.id == preferred })?.id ?? directories.first?.id
            selectedGalleryDirectoryID = selected

            guard let selected else {
                galleryItems = []
                thumbnailCache = [:]
                objectImageCache = [:]
                durationCache = [:]
                appendLog("[图库] 没有可选择的目录")
                return
            }

            await loadGalleryMedia(forDirectoryID: selected, clearCaches: true)
        } catch {
            appendLog("[图库] 目录列表失败 error=\(error.localizedDescription)")
        }
    }

    /// Switch directory: clear current gallery and load the chosen folder.
    func selectGalleryDirectory(id: UInt32) async {
        guard galleryDirectories.contains(where: { $0.id == id }) else {
            appendLog("[图库] 目录不存在 handle=0x\(String(format: "%08X", id))")
            return
        }
        if selectedGalleryDirectoryID == id, !galleryItems.isEmpty {
            return
        }
        selectedGalleryDirectoryID = id
        galleryItems = []
        thumbnailCache = [:]
        objectImageCache = [:]
        durationCache = [:]
        await loadGalleryMedia(forDirectoryID: id, clearCaches: true)
    }

    private func loadGalleryMedia(forDirectoryID directoryID: UInt32, clearCaches: Bool) async {
        guard case .connected = state, let commandConnection else {
            galleryItems = []
            appendLog("[图库] 未连接相机，跳过媒体加载")
            return
        }
        guard let directory = galleryDirectories.first(where: { $0.id == directoryID }) else {
            galleryItems = []
            appendLog("[图库] 媒体加载失败：目录无效")
            return
        }

        if clearCaches {
            thumbnailCache = [:]
            objectImageCache = [:]
            durationCache = [:]
        }

        let startedAt = Date()
        appendLog("[图库] 开始加载目录 \(directory.pickerTitle) path=\(directory.path) handle=0x\(String(format: "%08X", directory.handle))")
        do {
            let items = try await loadMediaItems(in: directory, on: commandConnection)
            galleryItems = items
            let photos = items.filter { !$0.isVideo }.count
            let videos = items.filter(\.isVideo).count
            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            appendLog(
                "[图库] 目录媒体完成 dir=\(directory.pickerTitle) photos=\(photos) videos=\(videos) " +
                "total=\(items.count) elapsedMs=\(elapsedMs)"
            )
        } catch {
            galleryItems = []
            appendLog("[图库] 目录媒体失败 dir=\(directory.pickerTitle) error=\(error.localizedDescription)")
        }
    }

    func thumbnailImage(for handle: UInt32) async -> UIImage? {
        if let cached = thumbnailCache[handle], let image = UIImage(data: cached) {
            return image
        }
        guard case .connected = state, let commandConnection else {
            appendLog("[图库] 缩略图跳过 handle=0x\(String(format: "%08X", handle)) reason=未连接")
            return nil
        }

        let filename = galleryItems.first(where: { $0.handle == handle })?.filename
        do {
            let response = try await operation(
                .getThumb,
                parameters: [handle],
                dataPhase: .receive,
                on: commandConnection,
                logStyle: .silent
            )
            guard response.code == PTPResponseCode.ok.rawValue, let data = response.data, !data.isEmpty else {
                appendLog(
                    "[图库] 缩略图失败 \(galleryItemLabel(handle: handle, filename: filename)) " +
                    "code=0x\(String(format: "%04X", response.code)) bytes=\(response.data?.count ?? 0)"
                )
                return nil
            }
            thumbnailCache[handle] = data
            return UIImage(data: data)
        } catch {
            appendLog("[图库] 缩略图异常 \(galleryItemLabel(handle: handle, filename: filename)) error=\(error.localizedDescription)")
            return nil
        }
    }

    /// Downloads the original object bytes without decoding or recompressing them.
    func objectData(for handle: UInt32) async -> Data? {
        if let cached = objectImageCache[handle] { return cached }
        guard case .connected = state, let commandConnection else { return nil }
        do {
            let response = try await operation(.getObject, parameters: [handle], dataPhase: .receive, on: commandConnection, logStyle: .silent)
            guard response.code == PTPResponseCode.ok.rawValue, let data = response.data, !data.isEmpty else { return nil }
            objectImageCache[handle] = data
            return data
        } catch {
            appendLog("[图库] 原始文件下载失败 handle=0x\(String(format: "%08X", handle)) error=\(error.localizedDescription)")
            return nil
        }
    }

    /// Loads and caches the original image for full-screen preview.
    /// Videos intentionally use their thumbnail in the gallery preview.
    func objectImage(for handle: UInt32) async -> UIImage? {
        if let cached = objectImageCache[handle], let image = UIImage(data: cached) {
            return image
        }
        guard case .connected = state, let commandConnection else { return nil }

        let filename = galleryItems.first(where: { $0.handle == handle })?.filename
        do {
            let response = try await operation(
                .getObject,
                parameters: [handle],
                dataPhase: .receive,
                on: commandConnection,
                logStyle: .silent
            )
            guard response.code == PTPResponseCode.ok.rawValue,
                  let data = response.data,
                  !data.isEmpty,
                  let image = UIImage(data: data) else {
                appendLog(
                    "[图库] 原图失败 \(galleryItemLabel(handle: handle, filename: filename)) " +
                    "code=0x\(String(format: "%04X", response.code)) bytes=\(response.data?.count ?? 0)"
                )
                return nil
            }
            objectImageCache[handle] = data
            return image
        } catch {
            appendLog("[图库] 原图异常 \(galleryItemLabel(handle: handle, filename: filename)) error=\(error.localizedDescription)")
            return nil
        }
    }

    func videoDurationSeconds(for handle: UInt32) async -> Int? {
        if let cached = durationCache[handle] {
            return cached
        }
        guard case .connected = state, let commandConnection else { return nil }
        return await fetchVideoDurationSeconds(handle: handle, on: commandConnection)
    }

    func clearDebugLog() {
        debugLog = ""
    }

    private func operation(
        _ code: PTPOperationCode,
        parameters: [UInt32],
        dataPhase: DataPhase?,
        on connection: NWConnection,
        logStyle: OperationLogStyle = .verbose
    ) async throws -> PTPResponse {
        await acquireOperationSlot()
        defer { releaseOperationSlot() }

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

        if logStyle != .silent {
            appendLog(
                "[command] OperationRequest name=\(code.debugName) code=0x\(String(format: "%04X", code.rawValue)) " +
                "transaction=\(currentTransactionID) parameters=\(parameters.map { String(format: "0x%08X", $0) }.joined(separator: ","))"
            )
        }

        try await send(
            ptpIPPacket(type: .operationRequest, payload: operationPayload),
            on: connection,
            logStyle: logStyle
        )

        var receivedData = Data()
        while true {
            let packet = try await receivePacket(on: connection, logStyle: logStyle)
            switch packet.type {
            case PTPIPPacketType.startData.rawValue:
                guard packet.payload.count >= 12 else {
                    appendLog("[command] StartData 报文异常 name=\(code.debugName) transaction=\(currentTransactionID)")
                    throw CameraConnectionError.malformedPacket
                }
                let dataTransactionID = packet.payload.uint32(at: 0)
                guard dataTransactionID == currentTransactionID else {
                    appendLog("[command] StartData 事务号不匹配 name=\(code.debugName) expected=\(currentTransactionID) actual=\(dataTransactionID)")
                    throw CameraConnectionError.transactionMismatch
                }
                continue
            case PTPIPPacketType.data.rawValue:
                guard packet.payload.count >= 4 else {
                    appendLog("[command] Data 报文异常 name=\(code.debugName) transaction=\(currentTransactionID)")
                    throw CameraConnectionError.malformedPacket
                }
                guard packet.payload.uint32(at: 0) == currentTransactionID else {
                    appendLog("[command] Data 事务号不匹配 name=\(code.debugName) transaction=\(currentTransactionID)")
                    throw CameraConnectionError.transactionMismatch
                }
                receivedData.append(packet.payload.dropFirst(4))
            case PTPIPPacketType.endData.rawValue:
                guard packet.payload.count >= 4 else {
                    appendLog("[command] EndData 报文异常 name=\(code.debugName) transaction=\(currentTransactionID)")
                    throw CameraConnectionError.malformedPacket
                }
                guard packet.payload.uint32(at: 0) == currentTransactionID else {
                    appendLog("[command] EndData 事务号不匹配 name=\(code.debugName) transaction=\(currentTransactionID)")
                    throw CameraConnectionError.transactionMismatch
                }
                receivedData.append(packet.payload.dropFirst(4))
            case PTPIPPacketType.operationResponse.rawValue:
                guard packet.payload.count >= 6 else {
                    appendLog("[command] OperationResponse 报文异常 name=\(code.debugName) transaction=\(currentTransactionID)")
                    throw CameraConnectionError.malformedPacket
                }
                let responseCode = packet.payload.uint16(at: 0)
                let responseTransactionID = packet.payload.uint32(at: 2)
                guard responseTransactionID == currentTransactionID else {
                    appendLog("[command] 事务号不匹配 expected=\(currentTransactionID) actual=\(responseTransactionID)")
                    throw CameraConnectionError.transactionMismatch
                }
                if logStyle != .silent {
                    appendLog(
                        "[command] OperationResponse name=\(code.debugName) code=0x\(String(format: "%04X", responseCode)) " +
                        "transaction=\(responseTransactionID) dataBytes=\(receivedData.count)"
                    )
                } else if responseCode != PTPResponseCode.ok.rawValue {
                    appendLog(
                        "[command] OperationResponse name=\(code.debugName) code=0x\(String(format: "%04X", responseCode)) " +
                        "transaction=\(responseTransactionID) dataBytes=\(receivedData.count)"
                    )
                }
                return PTPResponse(code: responseCode, data: dataPhase == .receive ? receivedData : nil)
            default:
                if logStyle != .silent {
                    appendLog("[command] 忽略未预期包 type=\(packet.typeName)")
                }
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

    private func send(_ packet: Data, on connection: NWConnection, logStyle: OperationLogStyle = .verbose) async throws {
        switch logStyle {
        case .verbose:
            appendLog("发送 PTP/IP type=\(packet.packetTypeName) totalBytes=\(packet.count) hex=\(packet.hexDump)")
        case .compact:
            appendLog("发送 PTP/IP type=\(packet.packetTypeName) totalBytes=\(packet.count)")
        case .silent:
            break
        }
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

    private func receivePacket(on connection: NWConnection, logStyle: OperationLogStyle = .verbose) async throws -> PTPIPPacket {
        let header = try await receiveExactly(8, on: connection)
        let totalLength = Int(header.uint32(at: 0))
        guard totalLength >= 8 else {
            appendLog("接收报文长度非法 totalLength=\(totalLength) header=\(header.hexDump)")
            throw CameraConnectionError.malformedPacket
        }
        let type = header.uint32(at: 4)
        let payload = totalLength > 8 ? try await receiveExactly(totalLength - 8, on: connection) : Data()
        let packet = PTPIPPacket(type: type, payload: payload)
        switch logStyle {
        case .verbose:
            appendLog("接收 PTP/IP type=\(packet.typeName) totalBytes=\(totalLength) payloadBytes=\(payload.count) hex=\(packet.hexDump)")
        case .compact:
            appendLog("接收 PTP/IP type=\(packet.typeName) totalBytes=\(totalLength) payloadBytes=\(payload.count)")
        case .silent:
            break
        }
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

    private func acquireOperationSlot() async {
        if !isOperationBusy {
            isOperationBusy = true
            return
        }
        await withCheckedContinuation { continuation in
            operationWaiters.append(continuation)
        }
    }

    private func releaseOperationSlot() {
        if operationWaiters.isEmpty {
            isOperationBusy = false
        } else {
            let next = operationWaiters.removeFirst()
            next.resume()
        }
    }

    private func loadGalleryDirectories(on connection: NWConnection) async throws -> [GalleryDirectory] {
        let storageIDs = try await fetchStorageIDs(on: connection)
        if storageIDs.isEmpty {
            appendLog("[图库] 未发现可用存储")
            return []
        }
        appendLog(
            "[图库] 存储数量 count=\(storageIDs.count) ids=" +
            storageIDs.map { String(format: "0x%08X", $0) }.joined(separator: ",")
        )

        var directories: [GalleryDirectory] = []
        var seenDirectoryHandles = Set<UInt32>()
        var rootHasDirectMedia = false

        for storageID in storageIDs {
            // Seed from root objects.
            var seedHandles: [UInt32] = []
            if let root = try? await fetchObjectHandles(
                storageID: storageID,
                objectFormat: 0,
                parent: 0xFFFF_FFFF,
                on: connection
            ) {
                appendLog(
                    "[图库] 根目录句柄 storageID=0x\(String(format: "%08X", storageID)) count=\(root.count)"
                )
                seedHandles.append(contentsOf: root)
            }

            // Walk folders breadth-first. Keep folders that directly contain media.
            var queue: [(handle: UInt32?, pathPrefix: String)] = [(nil, "")]
            // nil handle means "inspect seed/root children".
            var queued = Set<UInt32>()
            var index = 0

            // First process root seed as path ""
            while index < queue.count {
                let node = queue[index]
                index += 1

                let childHandles: [UInt32]
                if let folderHandle = node.handle {
                    do {
                        childHandles = try await fetchObjectHandles(
                            storageID: storageID,
                            objectFormat: 0,
                            parent: folderHandle,
                            on: connection
                        )
                    } catch {
                        appendLog(
                            "[图库] 目录子项失败 parent=0x\(String(format: "%08X", folderHandle)) " +
                            "error=\(error.localizedDescription)"
                        )
                        continue
                    }
                } else {
                    childHandles = seedHandles
                }

                var directMediaCount = 0
                var subfolders: [(handle: UInt32, name: String)] = []

                for child in childHandles {
                    guard let info = try? await fetchObjectInfo(handle: child, on: connection) else {
                        continue
                    }
                    if isAssociationObject(objectFormat: info.objectFormat) {
                        subfolders.append((child, info.filename))
                        continue
                    }
                    if isGalleryMedia(objectFormat: info.objectFormat, filename: info.filename) {
                        directMediaCount += 1
                    }
                }

                if let folderHandle = node.handle {
                    if !seenDirectoryHandles.contains(folderHandle) {
                        seenDirectoryHandles.insert(folderHandle)
                        let name = node.pathPrefix.split(separator: "/").last.map(String.init) ?? node.pathPrefix
                        let directory = GalleryDirectory(
                            id: folderHandle,
                            storageID: storageID,
                            name: name.isEmpty ? String(format: "0x%08X", folderHandle) : name,
                            path: node.pathPrefix,
                            isSyntheticRoot: false
                        )
                        directories.append(directory)
                        appendLog(
                            "[图库] 可选目录 \(directory.pickerTitle) path=\(directory.path) " +
                            "media=\(directMediaCount) handle=0x\(String(format: "%08X", folderHandle))"
                        )
                    }
                } else if directMediaCount > 0 {
                    rootHasDirectMedia = true
                }

                for subfolder in subfolders where !queued.contains(subfolder.handle) {
                    queued.insert(subfolder.handle)
                    let nextPath: String
                    if node.pathPrefix.isEmpty {
                        nextPath = subfolder.name
                    } else {
                        nextPath = node.pathPrefix + "/" + subfolder.name
                    }
                    queue.append((subfolder.handle, nextPath))
                }
            }
        }

        if rootHasDirectMedia {
            // Synthetic root entry for media living outside folders.
            let root = GalleryDirectory(
                id: 0,
                storageID: storageIDs[0],
                name: "根目录",
                path: "/",
                isSyntheticRoot: true
            )
            directories.insert(root, at: 0)
            appendLog("[图库] 加入合成根目录（根级直接媒体）")
        }

        // Stable order: path/name ascending, root first.
        directories.sort { lhs, rhs in
            if lhs.isSyntheticRoot != rhs.isSyntheticRoot {
                return lhs.isSyntheticRoot && !rhs.isSyntheticRoot
            }
            let l = lhs.path.isEmpty ? lhs.name : lhs.path
            let r = rhs.path.isEmpty ? rhs.name : rhs.path
            if l != r { return l.localizedStandardCompare(r) == .orderedAscending }
            return lhs.handle < rhs.handle
        }

        return directories
    }

    private func loadMediaItems(
        in directory: GalleryDirectory,
        on connection: NWConnection
    ) async throws -> [GalleryItem] {
        let rootHandles = try await fetchObjectHandles(
            storageID: directory.storageID,
            objectFormat: 0,
            parent: directory.isSyntheticRoot ? 0xFFFF_FFFF : directory.handle,
            on: connection
        )

        appendLog("[图库] 读取目录内容 dir=\(directory.pickerTitle) children=\(rootHandles.count)")

        var items: [GalleryItem] = []
        var skippedNonMedia = 0
        var skippedErrors = 0
        var visited = Set<UInt32>()
        var queue: [UInt32] = rootHandles
        var processed = 0

        while !queue.isEmpty {
            let handle = queue.removeFirst()
            if !visited.insert(handle).inserted { continue }
            processed += 1
            do {
                guard let info = try await fetchObjectInfo(handle: handle, on: connection) else {
                    skippedErrors += 1
                    continue
                }
                if isAssociationObject(objectFormat: info.objectFormat) {
                    let descendants = try await fetchObjectHandles(
                        storageID: directory.storageID,
                        objectFormat: 0,
                        parent: handle,
                        on: connection
                    )
                    queue.append(contentsOf: descendants)
                    appendLog(
                        "[图库] 递归目录 parent=0x\(String(format: "%08X", handle)) " +
                        "children=\(descendants.count)"
                    )
                    continue
                }
                guard isGalleryMedia(objectFormat: info.objectFormat, filename: info.filename) else {
                    skippedNonMedia += 1
                    continue
                }

                let isVideo = isVideoMedia(objectFormat: info.objectFormat, filename: info.filename)
                items.append(
                    GalleryItem(
                        id: handle,
                        filename: info.filename,
                        objectFormat: info.objectFormat,
                        fileSize: info.fileSize,
                        isVideo: isVideo,
                        captureDate: info.captureDate ?? info.modificationDate,
                        durationSeconds: isVideo ? durationCache[handle] : nil
                    )
                )
            } catch {
                skippedErrors += 1
                appendLog(
                    "[图库] ObjectInfo 跳过 handle=0x\(String(format: "%08X", handle)) " +
                    "error=\(error.localizedDescription)"
                )
            }

            if processed % 25 == 0 || queue.isEmpty {
                appendLog(
                    "[图库] 目录解析进度 dir=\(directory.pickerTitle) processed=\(processed) pending=\(queue.count) " +
                    "media=\(items.count)"
                )
            }
        }

        items.sort { lhs, rhs in
            switch (lhs.captureDate, rhs.captureDate) {
            case let (l?, r?):
                if l != r { return l > r }
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                break
            }
            return lhs.handle > rhs.handle
        }

        appendLog(
            "[图库] 目录解析结束 dir=\(directory.pickerTitle) media=\(items.count) " +
            "skippedNonMedia=\(skippedNonMedia) errors=\(skippedErrors)"
        )
        return items
    }

    private func fetchStorageIDs(on connection: NWConnection) async throws -> [UInt32] {
        let response = try await operation(
            .getStorageIDs,
            parameters: [],
            dataPhase: .receive,
            on: connection,
            logStyle: .silent
        )
        guard response.code == PTPResponseCode.ok.rawValue, let data = response.data, data.count >= 4 else {
            appendLog("[图库] GetStorageIDs 失败 code=0x\(String(format: "%04X", response.code))")
            throw CameraConnectionError.ptpResponse(response.code)
        }
        let count = Int(data.uint32(at: 0))
        let needed = 4 + count * 4
        guard count >= 0, data.count >= needed else {
            appendLog("[图库] GetStorageIDs 数据异常 bytes=\(data.count) count=\(count)")
            throw CameraConnectionError.malformedPacket
        }
        let ids = (0..<count).map { data.uint32(at: 4 + $0 * 4) }
        let present = ids.filter { ($0 & 0x0000_FFFF) != 0 }
        return present.isEmpty ? ids : present
    }

    private func fetchObjectHandles(
        storageID: UInt32,
        objectFormat: UInt32,
        parent: UInt32,
        on connection: NWConnection
    ) async throws -> [UInt32] {
        let response = try await operation(
            .getObjectHandles,
            parameters: [storageID, objectFormat, parent],
            dataPhase: .receive,
            on: connection,
            logStyle: .silent
        )
        guard response.code == PTPResponseCode.ok.rawValue, let data = response.data, data.count >= 4 else {
            appendLog(
                "[图库] GetObjectHandles 失败 storageID=0x\(String(format: "%08X", storageID)) " +
                "parent=0x\(String(format: "%08X", parent)) code=0x\(String(format: "%04X", response.code))"
            )
            throw CameraConnectionError.ptpResponse(response.code)
        }

        let count = Int(data.uint32(at: 0))
        let needed = 4 + count * 4
        guard data.count >= needed else {
            appendLog(
                "[图库] GetObjectHandles 数据异常 storageID=0x\(String(format: "%08X", storageID)) " +
                "parent=0x\(String(format: "%08X", parent)) bytes=\(data.count) count=\(count)"
            )
            throw CameraConnectionError.malformedPacket
        }

        var handles: [UInt32] = []
        handles.reserveCapacity(count)
        for index in 0..<count {
            handles.append(data.uint32(at: 4 + index * 4))
        }
        return handles
    }

    private func galleryItemLabel(handle: UInt32, filename: String?) -> String {
        if let filename, !filename.isEmpty {
            return "\(filename) handle=0x\(String(format: "%08X", handle))"
        }
        return "handle=0x\(String(format: "%08X", handle))"
    }

    private func isAssociationObject(objectFormat: UInt16) -> Bool {
        objectFormat == 0x3001
    }

    private struct ParsedObjectInfo {
        var objectFormat: UInt16
        var fileSize: UInt64
        var filename: String
        var captureDate: Date?
        var modificationDate: Date?
    }

    private func fetchObjectInfo(handle: UInt32, on connection: NWConnection) async throws -> ParsedObjectInfo? {
        let response = try await operation(
            .getObjectInfo,
            parameters: [handle],
            dataPhase: .receive,
            on: connection,
            logStyle: .silent
        )
        guard response.code == PTPResponseCode.ok.rawValue, let data = response.data else {
            appendLog(
                "[图库] GetObjectInfo 失败 handle=0x\(String(format: "%08X", handle)) " +
                "code=0x\(String(format: "%04X", response.code)) bytes=\(response.data?.count ?? 0)"
            )
            return nil
        }
        return try parseObjectInfo(data)
    }

    private func parseObjectInfo(_ data: Data) throws -> ParsedObjectInfo {
        guard data.count >= 52 else {
            throw CameraConnectionError.malformedPacket
        }

        let objectFormat = data.uint16(at: 4)
        let fileSize = UInt64(data.uint32(at: 8))
        var offset = 52
        let filename = try readPTPString(from: data, offset: offset)
        offset = filename.nextOffset
        let captureDate = try readPTPString(from: data, offset: offset)
        offset = captureDate.nextOffset
        let modificationDate = try readPTPString(from: data, offset: offset)

        return ParsedObjectInfo(
            objectFormat: objectFormat,
            fileSize: fileSize,
            filename: filename.value,
            captureDate: parsePTPDateTime(captureDate.value),
            modificationDate: parsePTPDateTime(modificationDate.value)
        )
    }

    private func fetchVideoDurationSeconds(handle: UInt32, on connection: NWConnection) async -> Int? {
        if let cached = durationCache[handle] {
            return cached
        }

        let filename = galleryItems.first(where: { $0.handle == handle })?.filename

        // MTP ObjectPropCode Duration = 0xDC89, typically milliseconds.
        do {
            let response = try await operation(
                .getObjectPropValue,
                parameters: [handle, 0x0000_DC89],
                dataPhase: .receive,
                on: connection,
                logStyle: .silent
            )
            guard response.code == PTPResponseCode.ok.rawValue,
                  let data = response.data,
                  let raw = readIntegerValue(from: data),
                  raw > 0 else {
                // Many cameras omit Duration; keep the log quiet unless it's an unexpected hard failure.
                if response.code != PTPResponseCode.ok.rawValue,
                   response.code != 0x200A, // DevicePropNotSupported-ish / common reject
                   response.code != 0xA801 {
                    appendLog(
                        "[图库] 视频时长读取被拒 \(galleryItemLabel(handle: handle, filename: filename)) " +
                        "code=0x\(String(format: "%04X", response.code))"
                    )
                }
                return nil
            }

            let seconds: Int
            if raw >= 1000 {
                seconds = Int(raw / 1000)
            } else {
                seconds = Int(raw)
            }
            durationCache[handle] = seconds
            if let index = galleryItems.firstIndex(where: { $0.handle == handle }) {
                var items = galleryItems
                items[index].durationSeconds = seconds
                galleryItems = items
            }
            return seconds
        } catch {
            appendLog(
                "[图库] 视频时长读取异常 \(galleryItemLabel(handle: handle, filename: filename)) " +
                "error=\(error.localizedDescription)"
            )
            return nil
        }
    }

    private func isGalleryMedia(objectFormat: UInt16, filename: String) -> Bool {
        // Skip folders / associations and generic non-media scripts.
        if objectFormat == 0x3001 || objectFormat == 0x3002 || objectFormat == 0x3006 {
            return false
        }
        if isImageMedia(objectFormat: objectFormat, filename: filename) {
            return true
        }
        if isVideoMedia(objectFormat: objectFormat, filename: filename) {
            return true
        }
        return false
    }

    private func isImageMedia(objectFormat: UInt16, filename: String) -> Bool {
        switch objectFormat {
        case 0x3801, 0x3802, 0x3804, 0x3808, 0x380D, 0x3811, 0xB802, 0xB80A:
            return true
        default:
            break
        }
        let ext = fileExtension(filename)
        return ["JPG", "JPEG", "HEIC", "HEIF", "TIF", "TIFF", "PNG", "NEF", "NRW", "DNG", "CR2", "CR3", "ARW"].contains(ext)
    }

    private func isVideoMedia(objectFormat: UInt16, filename: String) -> Bool {
        switch objectFormat {
        case 0x3008, 0x3009, 0x300A, 0x300B, 0x300C, 0x300D, 0xB982, 0xB984:
            return true
        default:
            break
        }
        let ext = fileExtension(filename)
        return ["MOV", "MP4", "M4V", "AVI", "MPEG", "MPG", "MTS", "MXF"].contains(ext)
    }

    private func fileExtension(_ filename: String) -> String {
        guard let dot = filename.lastIndex(of: ".") else { return "" }
        return String(filename[filename.index(after: dot)...]).uppercased()
    }

    private func parsePTPDateTime(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 15 else { return nil }
        let core = String(trimmed.prefix(15))

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        return formatter.date(from: core)
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

    private func readLensInfo(on connection: NWConnection) async -> LensInfo {
        var info = LensInfo(connectionState: .unknown)
        appendLog("开始读取镜头信息")

        // Nikon vendor properties observed in libgphoto2 / camera dumps:
        // LensID 0xD0E0, LensType 0xD0E2, FocalLengthMin/Max 0xD0E3/0xD0E4,
        // MaxApAtMin/MaxFocal 0xD0E5/0xD0E6. Standard PTP current values:
        // FNumber 0x5007, FocalLength 0x5008. Scale is value / 100.
        if let response = try? await operation(.getDevicePropValue, parameters: [0xD0E0], dataPhase: .receive, on: connection),
           response.code == PTPResponseCode.ok.rawValue,
           let data = response.data,
           let value = readIntegerValue(from: data) {
            info.lensID = UInt16(clamping: value)
            appendLog("镜头 LensID=0x\(String(format: "%04X", info.lensID ?? 0)) raw=\(value)")
        }

        if let response = try? await operation(.getDevicePropValue, parameters: [0xD0E2], dataPhase: .receive, on: connection),
           response.code == PTPResponseCode.ok.rawValue,
           let data = response.data,
           let value = readIntegerValue(from: data) {
            info.lensType = UInt32(clamping: value)
            appendLog("镜头 LensType=\(value)")
        }

        if let response = try? await operation(.getDevicePropValue, parameters: [0xD0E3], dataPhase: .receive, on: connection),
           response.code == PTPResponseCode.ok.rawValue,
           let data = response.data,
           let value = readIntegerValue(from: data) {
            info.minFocalLengthMM = Double(value) / 100.0
        }

        if let response = try? await operation(.getDevicePropValue, parameters: [0xD0E4], dataPhase: .receive, on: connection),
           response.code == PTPResponseCode.ok.rawValue,
           let data = response.data,
           let value = readIntegerValue(from: data) {
            info.maxFocalLengthMM = Double(value) / 100.0
        }

        if let response = try? await operation(.getDevicePropValue, parameters: [0xD0E5], dataPhase: .receive, on: connection),
           response.code == PTPResponseCode.ok.rawValue,
           let data = response.data,
           let value = readIntegerValue(from: data) {
            info.maxApertureAtMinFocal = Double(value) / 100.0
        }

        if let response = try? await operation(.getDevicePropValue, parameters: [0xD0E6], dataPhase: .receive, on: connection),
           response.code == PTPResponseCode.ok.rawValue,
           let data = response.data,
           let value = readIntegerValue(from: data) {
            info.maxApertureAtMaxFocal = Double(value) / 100.0
        }

        if let response = try? await operation(.getDevicePropValue, parameters: [0x5008], dataPhase: .receive, on: connection),
           response.code == PTPResponseCode.ok.rawValue,
           let data = response.data,
           let value = readIntegerValue(from: data) {
            info.currentFocalLengthMM = Double(value) / 100.0
        }

        if let response = try? await operation(.getDevicePropValue, parameters: [0x5007], dataPhase: .receive, on: connection),
           response.code == PTPResponseCode.ok.rawValue,
           let data = response.data,
           let value = readIntegerValue(from: data) {
            info.currentAperture = Double(value) / 100.0
        }

        let hasAnyLensMetric =
            info.lensID != nil
            || info.minFocalLengthMM != nil
            || info.maxFocalLengthMM != nil
            || info.maxApertureAtMinFocal != nil
            || info.maxApertureAtMaxFocal != nil
            || info.currentFocalLengthMM != nil
            || info.currentAperture != nil

        if !hasAnyLensMetric {
            info.connectionState = .unknown
            appendLog("镜头信息读取失败或属性不受支持")
            return info
        }

        let looksDetached =
            (info.lensID == 0 || info.lensID == nil)
            && (info.minFocalLengthMM ?? 0) == 0
            && (info.maxFocalLengthMM ?? 0) == 0
            && (info.currentFocalLengthMM ?? 0) == 0

        if looksDetached {
            info.connectionState = .noneAttached
        } else {
            info.connectionState = .connected
        }

        appendLog(
            "镜头信息 state=\(info.connectionState.title) id=\(info.lensID.map(String.init) ?? "--") " +
            "focal=\(info.minFocalLengthMM.map(formatFocalLength) ?? "--")-\(info.maxFocalLengthMM.map(formatFocalLength) ?? "--") " +
            "aperture=\(info.maxApertureAtMinFocal.map(formatAperture) ?? "--")-\(info.maxApertureAtMaxFocal.map(formatAperture) ?? "--") " +
            "currentFocal=\(info.currentFocalLengthMM.map(formatFocalLength) ?? "--") " +
            "currentAperture=\(info.currentAperture.map(formatAperture) ?? "--")"
        )
        return info
    }

    private func readIntegerValue(from data: Data) -> UInt64? {
        switch data.count {
        case 0:
            return nil
        case 1:
            return UInt64(data[0])
        case 2:
            return UInt64(data.uint16(at: 0))
        case 3...4:
            // Some cameras pad UINT16 values; prefer exact width first.
            if data.count == 4 {
                return UInt64(data.uint32(at: 0))
            }
            return UInt64(data.uint16(at: 0))
        default:
            if data.count >= 8 {
                return data.uint64(at: 0)
            }
            if data.count >= 4 {
                return UInt64(data.uint32(at: 0))
            }
            if data.count >= 2 {
                return UInt64(data.uint16(at: 0))
            }
            return UInt64(data[0])
        }
    }

    private func formatFocalLength(_ mm: Double) -> String {
        if mm.rounded() == mm {
            return String(format: "%.0fmm", mm)
        }
        return String(format: "%.1fmm", mm)
    }

    private func formatAperture(_ value: Double) -> String {
        if abs(value.rounded() - value) < 0.05 {
            return String(format: "f/%.0f", value)
        }
        let tenths = (value * 10).rounded() / 10
        if abs(tenths - value) < 0.02 {
            return String(format: "f/%.1f", tenths)
        }
        return String(format: "f/%.2f", value)
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
            serialNumber: Self.normalizedSerialNumber(serial.value)
        )
    }


    private static func normalizedSerialNumber(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        // Nikon DeviceInfo often left-pads the serial with zeros.
        if trimmed.allSatisfy({ $0.isNumber }) {
            let stripped = String(trimmed.drop(while: { $0 == "0" }))
            return stripped.isEmpty ? "0" : stripped
        }
        return trimmed
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

private enum OperationLogStyle {
    /// Connection setup: include packet hex dumps.
    case verbose
    /// One-line packet size logs without hex payloads.
    case compact
    /// Suppress routine transport logs; caller records progress/errors.
    case silent
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
    case getObjectHandles = 0x1007
    case getObjectInfo = 0x1008
    case getObject = 0x1009
    case getThumb = 0x100A
    case getDevicePropValue = 0x1015
    case getObjectPropValue = 0x9803

    var debugName: String {
        switch self {
        case .getDeviceInfo: return "GetDeviceInfo"
        case .openSession: return "OpenSession"
        case .getStorageIDs: return "GetStorageIDs"
        case .getStorageInfo: return "GetStorageInfo"
        case .getNumObjects: return "GetNumObjects"
        case .getObjectHandles: return "GetObjectHandles"
        case .getObjectInfo: return "GetObjectInfo"
        case .getObject: return "GetObject"
        case .getThumb: return "GetThumb"
        case .getDevicePropValue: return "GetDevicePropValue"
        case .getObjectPropValue: return "GetObjectPropValue"
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
        let limit = 256
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
