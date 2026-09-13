//
//  CameraConnectionService.swift
//  ZLinks
//

import Combine
import Foundation
import Network
import UIKit

@MainActor
final class CameraConnectionService: ObservableObject {
    static let autoConnectOnLaunchKey = "camera.autoConnectOnLaunch"

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

    enum GalleryPhotoFormat: String, Equatable, Hashable, Sendable {
        case raw
        case rawAndJPEG
        case jpeg

        var title: String {
            switch self {
            case .raw: return "RAW"
            case .rawAndJPEG: return "RAW + JPEG"
            case .jpeg: return "JPEG"
            }
        }

        var thumbnailSymbol: String? {
            switch self {
            case .raw: return "r.square.fill"
            case .rawAndJPEG: return "r.square.on.square.fill"
            case .jpeg: return nil
            }
        }

        var supportsRAW: Bool {
            self == .raw || self == .rawAndJPEG
        }

        var supportsJPEG: Bool {
            self == .jpeg || self == .rawAndJPEG
        }
    }

    enum GalleryImageLoadResult {
        case preview(UIImage)
        case original(UIImage)
    }

    struct GalleryItem: Identifiable, Equatable, Hashable, Sendable {
        let id: UInt32
        var handle: UInt32 { id }
        var filename: String
        var objectFormat: UInt16
        var fileSize: UInt64
        var isVideo: Bool
        var captureDate: Date?
        var rawHandle: UInt32?
        var rawFilename: String?
        var rawFileSize: UInt64?
        var jpegHandle: UInt32?
        var jpegFilename: String?
        var jpegFileSize: UInt64?

        var photoFormat: GalleryPhotoFormat? {
            guard !isVideo else { return nil }
            switch (rawHandle != nil, jpegHandle != nil) {
            case (true, true): return .rawAndJPEG
            case (true, false): return .raw
            case (false, true): return .jpeg
            case (false, false): return nil
            }
        }

        var thumbnailHandle: UInt32 {
            jpegHandle ?? rawHandle ?? handle
        }

        /// Full-screen previews prefer the paired JPEG because RAW objects are much larger.
        var previewHandle: UInt32 {
            jpegHandle ?? rawHandle ?? handle
        }
    }

    struct GalleryDirectory: Identifiable, Equatable, Hashable, Sendable {
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
    @Published private(set) var isReconnecting = false
    @Published private(set) var liveViewImage: UIImage?
    @Published private(set) var isLiveViewActive = false
    @Published private(set) var liveViewError: String?
    @Published private(set) var captureParameters: [CaptureParameter: UInt64] = [:]
    @Published private(set) var isRefreshingCaptureParameters = false
    @Published private(set) var activeCaptureWrite: CaptureParameter?
    @Published private(set) var captureControlError: String?
    @Published private(set) var isInitiatingCapture = false

    var isCaptureControlBusy: Bool {
        activeCaptureWrite != nil || captureWriteTask != nil
    }

    private var commandConnection: NWConnection?
    private var eventConnection: NWConnection?
    private var connectionNumber: UInt32?
    private var transactionID: UInt32 = 0
    private var isOperationBusy = false
    private var foregroundOperationWaiters: [CheckedContinuation<Void, Never>] = []
    private var backgroundOperationWaiters: [CheckedContinuation<Void, Never>] = []
    private var foregroundOperationWaiterIndex = 0
    private var backgroundOperationWaiterIndex = 0
    private var activeOperationTransactionID: UInt32?
    private var thumbnailCache: [UInt32: Data] = [:]
    private var previewImageCache: [UInt32: Data] = [:]
    private var objectImageCache: [UInt32: Data] = [:]
    private var supportsPreviewImage = false
    private var supportedOperations: Set<UInt16> = []
    private var galleryLoadGeneration = 0
    private var galleryEnrichmentTask: Task<Void, Never>?
    private var liveViewTask: Task<Void, Never>?
    private var liveViewGeneration = 0
    private var liveViewConsumers = 0
    private var lastEndpoint: NWEndpoint?
    private var lastDisplayHost: String?
    private var reconnectTask: Task<Void, Never>?
    private var connectionGeneration = UUID()
    private var pendingCaptureWrites: [CaptureParameter: UInt64] = [:]
    private var captureWriteTask: Task<Void, Never>?
    private var foregroundObserver: NSObjectProtocol?

    private static let lastConnectedHostKey = "camera.lastConnectedHost"

    init() {
        if let rememberedHost = UserDefaults.standard.string(forKey: Self.lastConnectedHostKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !rememberedHost.isEmpty {
            lastEndpoint = .hostPort(host: .init(rememberedHost), port: 15740)
            lastDisplayHost = rememberedHost
        }

        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleAppDidBecomeActive()
            }
        }
    }

    deinit {
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
    }

    func connect(host: String) async {
        await connect(endpoint: .hostPort(host: .init(host), port: 15740), displayHost: host)
    }

    func connect(endpoint: NWEndpoint, displayHost: String) async {
        reconnectTask?.cancel()
        reconnectTask = nil
        lastEndpoint = endpoint
        lastDisplayHost = displayHost
        await connect(endpoint: endpoint, displayHost: displayHost, preservingSession: false)
    }

    private func connect(endpoint: NWEndpoint, displayHost: String, preservingSession: Bool) async {
        appendLog("开始连接 endpoint=\(displayHost):15740")
        if preservingSession {
            disconnectConnections()
        } else {
            disconnect(clearRememberedDevice: false)
        }
        state = .connecting

        do {
            let command = NWConnection(to: endpoint, using: .tcp)
            commandConnection = command
            appendLog("[command] 创建 TCP 连接")
            try await start(command)
            appendLog("[command] TCP 已就绪")

            let guid = Data([
                0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
                0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff
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
            isReconnecting = false
            UserDefaults.standard.set(displayHost, forKey: Self.lastConnectedHostKey)
            appendLog("连接成功")
        } catch {
            appendLog("连接失败 error=\(String(reflecting: error)) description=\(error.localizedDescription)")
            disconnectConnections()
            if preservingSession {
                state = .disconnected
                isReconnecting = false
            } else {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func disconnect() {
        disconnect(clearRememberedDevice: true)
    }

    private func disconnect(clearRememberedDevice: Bool) {
        invalidateGalleryLoad()
        reconnectTask?.cancel()
        reconnectTask = nil
        isReconnecting = false
        disconnectConnections()
        cameraInfo = nil
        connectedHost = nil
        cameraStatus = CameraStatus()
        lensInfo = .disconnected
        galleryItems = []
        galleryDirectories = []
        selectedGalleryDirectoryID = nil
        thumbnailCache = [:]
        previewImageCache = [:]
        objectImageCache = [:]
        supportsPreviewImage = false
        supportedOperations = []
        captureParameters = [:]
        pendingCaptureWrites = [:]
        captureWriteTask?.cancel()
        captureWriteTask = nil
        activeCaptureWrite = nil
        isRefreshingCaptureParameters = false
        isInitiatingCapture = false
        captureControlError = nil
        stopLiveViewInternal(sendEndCommand: false)
        state = .disconnected

        if clearRememberedDevice {
            lastEndpoint = nil
            lastDisplayHost = nil
            UserDefaults.standard.removeObject(forKey: Self.lastConnectedHostKey)
        }
    }

    private func handleAppDidBecomeActive() {
        if case .connected = state {
            guard reconnectTask == nil else { return }
            let commandReady = commandConnection?.state == .ready
            let eventReady = eventConnection?.state == .ready
            guard !commandReady || !eventReady else { return }
            beginAutomaticReconnect(reason: "应用回到前台后检测到连接已断开")
            return
        }

        guard UserDefaults.standard.bool(forKey: Self.autoConnectOnLaunchKey),
              case .disconnected = state,
              reconnectTask == nil,
              lastEndpoint != nil,
              lastDisplayHost != nil
        else {
            return
        }
        beginAutomaticReconnect(reason: "应用启动后自动连接上次相机")
    }

    private func handleTransportFailure(_ connection: NWConnection, generation: UUID, reason: String) {
        guard generation == connectionGeneration else { return }
        guard commandConnection === connection || eventConnection === connection else { return }
        guard case .connected = state else { return }
        appendLog("检测到相机连接断开 reason=\(reason)")
        beginAutomaticReconnect(reason: reason)
    }

    private func noteTransportError(_ connection: NWConnection, reason: String) {
        handleTransportFailure(connection, generation: connectionGeneration, reason: reason)
    }

    private func beginAutomaticReconnect(reason: String) {
        if reconnectTask != nil { return }
        guard let endpoint = lastEndpoint, let displayHost = lastDisplayHost else {
            state = .disconnected
            return
        }
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            self.isReconnecting = true
            self.state = .connecting
            self.appendLog("开始自动重连 reason=\(reason)")

            for attempt in 1...3 {
                if Task.isCancelled { return }
                if attempt > 1 {
                    try? await Task.sleep(for: .seconds(1))
                }
                self.appendLog("自动重连第 \(attempt)/3 次")
                await self.connect(endpoint: endpoint, displayHost: displayHost, preservingSession: true)
                if case .connected = self.state {
                    self.reconnectTask = nil
                    return
                }
                if attempt < 3 {
                    self.state = .connecting
                    self.isReconnecting = true
                }
            }

            self.appendLog("自动重连失败，已变为未连接")
            self.disconnect(clearRememberedDevice: false)
        }
    }

    func refreshCameraStatus() async {
        guard case .connected = state, let commandConnection else { return }
        appendLog("开始刷新相机状态")
        cameraStatus = await readCameraStatus(on: commandConnection)
        lensInfo = await readLensInfo(on: commandConnection)
    }

    private func beginGalleryLoad() -> Int {
        invalidateGalleryLoad()
        return galleryLoadGeneration
    }

    private func invalidateGalleryLoad() {
        galleryLoadGeneration &+= 1
        galleryEnrichmentTask?.cancel()
        galleryEnrichmentTask = nil
    }

    private func isCurrentGalleryLoad(_ generation: Int, directoryID: UInt32? = nil) -> Bool {
        guard isMatchingGalleryLoad(generation, directoryID: directoryID), case .connected = state else {
            return false
        }
        return true
    }

    private func isMatchingGalleryLoad(_ generation: Int, directoryID: UInt32? = nil) -> Bool {
        guard generation == galleryLoadGeneration, !Task.isCancelled else { return false }
        if let directoryID {
            return selectedGalleryDirectoryID == directoryID
        }
        return true
    }

    private func waitForRecoveredCommandConnection(
        generation: Int,
        directoryID: UInt32
    ) async -> NWConnection? {
        for _ in 0..<60 {
            guard isMatchingGalleryLoad(generation, directoryID: directoryID) else { return nil }
            if case .connected = state,
               let connection = commandConnection,
               case .ready = connection.state
            {
                return connection
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return nil
    }

    /// Refresh directory list, keep/select a directory, then load that directory's media.
    func refreshGallery(selectingDirectoryID directoryID: UInt32? = nil) async {
        let generation = beginGalleryLoad()
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
            guard isCurrentGalleryLoad(generation) else { return }
            galleryDirectories = directories
            appendLog("[图库] 目录列表完成 count=\(directories.count)")

            let preferred = directoryID ?? selectedGalleryDirectoryID
            let selected = directories.first(where: { $0.id == preferred })?.id ?? directories.first?.id
            selectedGalleryDirectoryID = selected

            guard let selected else {
                galleryItems = []
                thumbnailCache = [:]
                objectImageCache = [:]
                appendLog("[图库] 没有可选择的目录")
                return
            }

            await loadGalleryMedia(forDirectoryID: selected, clearCaches: true, generation: generation)
        } catch {
            guard isCurrentGalleryLoad(generation) else { return }
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
        let generation = beginGalleryLoad()
        selectedGalleryDirectoryID = id
        galleryItems = []
        thumbnailCache = [:]
        previewImageCache = [:]
        objectImageCache = [:]
        await loadGalleryMedia(forDirectoryID: id, clearCaches: true, generation: generation)
    }

    private func loadGalleryMedia(
        forDirectoryID directoryID: UInt32,
        clearCaches: Bool,
        generation: Int
    ) async {
        guard case .connected = state, let commandConnection else {
            appendLog("[图库] 未连接相机，跳过媒体加载")
            return
        }
        guard let directory = galleryDirectories.first(where: { $0.id == directoryID }) else {
            appendLog("[图库] 媒体加载失败：目录无效")
            return
        }

        if clearCaches {
            thumbnailCache = [:]
            previewImageCache = [:]
            objectImageCache = [:]
        }

        let startedAt = Date()
        appendLog("[图库] 开始加载目录 \(directory.pickerTitle) path=\(directory.path) handle=0x\(String(format: "%08X", directory.handle))")
        var mediaConnection = commandConnection
        if supportedOperations.contains(PTPOperationCode.getObjectsMetadata.rawValue) {
            appendLog("[图库] GetObjectsMetaData可用")
            appendLog("[图库] 使用 GetObjectsMetaData 获取列表")
            do {
                let metadata = try await fetchNikonObjectsMetadata(in: directory, on: commandConnection)
                guard isCurrentGalleryLoad(generation, directoryID: directoryID) else { return }
                let records = metadata.records
                let skeleton = await Task.detached(priority: .userInitiated) {
                    records.map(Self.makeSkeletonItem)
                }.value
                guard isCurrentGalleryLoad(generation, directoryID: directoryID) else { return }
                galleryItems = skeleton
                appendLog("[图库] GetObjectsMetaData成功生成对象数=\(skeleton.count)")
                galleryEnrichmentTask = Task { [weak self] in
                    await self?.enrichMetadataGallery(
                        metadata,
                        in: directory,
                        on: commandConnection,
                        generation: generation
                    )
                }
                return
            } catch {
                guard isMatchingGalleryLoad(generation, directoryID: directoryID) else { return }
                appendLog("[图库] GetObjectsMetaData失败 reason=\(error.localizedDescription)")
                appendLog("[图库] GetObjectsMetaData失败，回退标准对象枚举")
                if case .ready = commandConnection.state {
                    mediaConnection = commandConnection
                } else if let recovered = await waitForRecoveredCommandConnection(
                    generation: generation,
                    directoryID: directoryID
                ) {
                    mediaConnection = recovered
                    appendLog("[图库] 连接恢复完成，开始标准对象枚举")
                } else {
                    appendLog("[图库] 标准对象枚举未启动 reason=连接恢复超时")
                    return
                }
            }
        } else {
            appendLog("[图库] 相机未公布 GetObjectsMetaData(0x9434)")
        }

        do {
            let items = try await loadMediaItems(
                in: directory,
                on: mediaConnection,
                generation: generation
            )
            guard isCurrentGalleryLoad(generation, directoryID: directoryID) else { return }
            galleryItems = items
            let photos = items.filter { !$0.isVideo }.count
            let videos = items.filter(\.isVideo).count
            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            appendLog(
                "[图库] 目录媒体完成 dir=\(directory.pickerTitle) photos=\(photos) videos=\(videos) " +
                    "total=\(items.count) elapsedMs=\(elapsedMs)"
            )
        } catch {
            guard isCurrentGalleryLoad(generation, directoryID: directoryID) else { return }
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

    /// Loads the fastest usable full-screen image. Nikon preview is attempted only when
    /// the connected camera advertises OperationCode 0x9200; invalid preview data falls
    /// back to the complete object read.
    func galleryPreviewImage(for handle: UInt32) async -> GalleryImageLoadResult? {
        if supportsPreviewImage {
            if let cached = previewImageCache[handle], let image = UIImage(data: cached) {
                return .preview(image)
            }

            guard case .connected = state, let commandConnection else { return nil }
            let filename = galleryItems.first(where: { $0.handle == handle })?.filename
            do {
                let response = try await operation(
                    .getPreviewImage,
                    parameters: [],
                    dataPhase: .receive,
                    on: commandConnection,
                    logStyle: .silent
                )
                if response.code == PTPResponseCode.ok.rawValue,
                   let data = response.data,
                   !data.isEmpty,
                   let image = UIImage(data: data)
                {
                    previewImageCache[handle] = data
                    appendLog("[图库] 高清预览成功 \(galleryItemLabel(handle: handle, filename: filename)) bytes=\(data.count)")
                    return .preview(image)
                }
                appendLog(
                    "[图库] 高清预览无效，回落原图 \(galleryItemLabel(handle: handle, filename: filename)) " +
                        "code=0x\(String(format: "%04X", response.code)) bytes=\(response.data?.count ?? 0)"
                )
            } catch {
                appendLog(
                    "[图库] 高清预览失败，回落原图 \(galleryItemLabel(handle: handle, filename: filename)) " +
                        "error=\(error.localizedDescription)"
                )
            }
        }

        return await objectImage(for: handle).map(GalleryImageLoadResult.original)
    }

    /// Loads and caches the original image with standard PTP partial-object reads.
    func objectImage(for handle: UInt32) async -> UIImage? {
        if let cached = objectImageCache[handle], let image = UIImage(data: cached) {
            return image
        }
        guard case .connected = state, let commandConnection else { return nil }

        let filename = galleryItems.first(where: { $0.handle == handle })?.filename
        do {
            let data = try await fetchPartialObject(handle: handle, on: commandConnection)
            guard !data.isEmpty, let image = UIImage(data: data) else {
                appendLog("[图库] 分块原图无效 \(galleryItemLabel(handle: handle, filename: filename)) bytes=\(data.count)")
                return nil
            }
            objectImageCache[handle] = data
            return image
        } catch {
            appendLog("[图库] 分块原图异常 \(galleryItemLabel(handle: handle, filename: filename)) error=\(error.localizedDescription)")
            return nil
        }
    }

    private func fetchPartialObject(handle: UInt32, on connection: NWConnection) async throws -> Data {
        let chunkSize: UInt32 = 4 * 1024 * 1024
        var offset: UInt32 = 0
        var collected = Data()

        while true {
            let response = try await operation(
                .getPartialObject,
                parameters: [handle, offset, chunkSize],
                dataPhase: .receive,
                on: connection,
                logStyle: .silent
            )
            guard response.code == PTPResponseCode.ok.rawValue,
                  let data = response.data,
                  !data.isEmpty
            else {
                throw CameraConnectionError.ptpResponse(response.code)
            }

            collected.append(data)
            let returnedBytes = response.parameters.first.map(Int.init) ?? data.count
            if returnedBytes < Int(chunkSize) || data.count < Int(chunkSize) {
                return collected
            }
            guard offset <= UInt32.max - UInt32(data.count) else {
                throw CameraConnectionError.malformedPacket
            }
            offset += UInt32(data.count)
        }
    }

    func clearDebugLog() {
        debugLog = ""
    }

    func clearCaptureControlError() {
        captureControlError = nil
    }

    /// Read the exposure-related PTP properties shown in the Capture tab.
    func refreshCaptureParameters() async {
        guard case .connected = state, let commandConnection else {
            captureParameters = [:]
            return
        }
        guard activeCaptureWrite == nil, captureWriteTask == nil, !isRefreshingCaptureParameters else { return }

        isRefreshingCaptureParameters = true
        captureControlError = nil
        defer { isRefreshingCaptureParameters = false }

        var values: [CaptureParameter: UInt64] = [:]
        for parameter in CaptureParameter.allCases {
            if Task.isCancelled { break }
            if let value = await readCaptureParameter(parameter, on: commandConnection) {
                values[parameter] = value
            }
        }

        if values.isEmpty {
            captureControlError = "相机未返回可控制的曝光参数。"
            appendLog("[capture] 参数读取失败：没有可用的曝光属性")
            return
        }

        captureParameters = values
        appendLog(
            "[capture] 参数读取完成 names=" +
                values.keys.map(\.title).sorted().joined(separator: ",")
        )
    }

    /// Queue a live slider value. Intermediate values are coalesced while a
    /// PTP transaction is in flight, so dragging never backs up the command
    /// channel and the camera always converges on the latest position.
    func queueCaptureParameter(_ parameter: CaptureParameter, rawValue: UInt64) {
        guard case .connected = state else {
            captureControlError = "相机未连接。"
            return
        }

        pendingCaptureWrites[parameter] = rawValue
        captureParameters[parameter] = rawValue
        captureControlError = nil

        guard captureWriteTask == nil else { return }
        captureWriteTask = Task { [weak self] in
            await self?.drainPendingCaptureWrites()
        }
    }

    /// Trigger the Nikon capture command that records the image to camera media.
    @discardableResult
    func initiateCaptureRecInMedia() async -> Bool {
        guard case .connected = state, let commandConnection else {
            captureControlError = "相机未连接。"
            return false
        }
        guard !isInitiatingCapture else { return false }

        isInitiatingCapture = true
        captureControlError = nil
        defer { isInitiatingCapture = false }

        do {
            let response = try await operation(
                .initiateCaptureRecInMedia,
                parameters: [],
                dataPhase: nil,
                on: commandConnection,
                logStyle: .compact,
                timeout: .seconds(8)
            )
            guard response.code == PTPResponseCode.ok.rawValue else {
                throw CameraConnectionError.ptpResponse(response.code)
            }
            appendLog("[capture] InitiateCaptureRecInMedia 成功")
            return true
        } catch {
            captureControlError = "拍摄失败：\(error.localizedDescription)"
            appendLog("[capture] InitiateCaptureRecInMedia 失败 error=\(error.localizedDescription)")
            return false
        }
    }

    private func drainPendingCaptureWrites() async {
        defer { captureWriteTask = nil }

        while !Task.isCancelled, !pendingCaptureWrites.isEmpty {
            guard case .connected = state else {
                pendingCaptureWrites = [:]
                break
            }
            guard let next = pendingCaptureWrites.first else { break }
            pendingCaptureWrites.removeValue(forKey: next.key)
            _ = await setCaptureParameter(next.key, rawValue: next.value)
        }
    }

    /// Write one camera parameter and immediately read it back to show the
    /// value the body actually accepted.
    @discardableResult
    func setCaptureParameter(_ parameter: CaptureParameter, rawValue: UInt64) async -> Bool {
        guard case .connected = state, let commandConnection else {
            captureControlError = "相机未连接。"
            return false
        }
        guard activeCaptureWrite == nil else { return false }

        let previousValue = captureParameters[parameter]
        activeCaptureWrite = parameter
        captureParameters[parameter] = rawValue
        captureControlError = nil
        defer { activeCaptureWrite = nil }

        do {
            var response = try await operation(
                .setDevicePropValue,
                parameters: [UInt32(parameter.rawValue)],
                dataPhase: .send(parameter.standardData(for: rawValue)),
                on: commandConnection,
                logStyle: .compact,
                timeout: .seconds(5)
            )

            var usedFallback = false
            if response.code != PTPResponseCode.ok.rawValue,
               let fallbackCode = parameter.nikonFallbackCode,
               let fallbackData = parameter.fallbackData(for: rawValue) {
                appendLog(
                    "[capture] \(parameter.title) 标准属性失败 code=0x" +
                        String(format: "%04X", response.code) +
                        "，尝试 Nikon 0x\(String(format: "%04X", fallbackCode))"
                )
                response = try await operation(
                    .setDevicePropValue,
                    parameters: [UInt32(fallbackCode)],
                    dataPhase: .send(fallbackData),
                    on: commandConnection,
                    logStyle: .compact,
                    timeout: .seconds(5)
                )
                usedFallback = true
            }

            guard response.code == PTPResponseCode.ok.rawValue else {
                throw CameraConnectionError.ptpResponse(response.code)
            }

            appendLog(
                "[capture] 参数写入成功 name=\(parameter.title) raw=\(rawValue) " +
                    "fallback=\(usedFallback)"
            )

            // Let the body settle before refreshing the real value. This keeps
            // the UI truthful when the camera clamps a value to its own steps.
            try? await Task.sleep(for: .milliseconds(180))
            if let actualValue = await readCaptureParameter(parameter, on: commandConnection) {
                captureParameters[parameter] = actualValue
                appendLog("[capture] 参数回读 name=\(parameter.title) raw=\(actualValue)")
            }
            return true
        } catch {
            if let previousValue {
                captureParameters[parameter] = previousValue
            } else {
                captureParameters.removeValue(forKey: parameter)
            }
            captureControlError = "\(parameter.title)修改失败：\(error.localizedDescription)"
            appendLog("[capture] 参数写入失败 name=\(parameter.title) error=\(error.localizedDescription)")
            return false
        }
    }

    private func readCaptureParameter(
        _ parameter: CaptureParameter,
        on connection: NWConnection
    ) async -> UInt64? {
        if let value = await readDeviceProperty(parameter.rawValue, on: connection) {
            return parameter.normalizeStandardRead(value)
        }
        if let fallbackCode = parameter.nikonFallbackCode,
           let value = await readDeviceProperty(fallbackCode, on: connection) {
            return parameter.normalizeFallbackRead(value)
        }
        return nil
    }

    /// Begin requesting Nikon live-view frames for the Capture tab.
    /// Safe to call repeatedly; consumers are reference-counted.
    func startLiveView() async {
        liveViewConsumers += 1
        liveViewError = nil
        guard liveViewConsumers == 1 else { return }
        await beginLiveViewSession()
    }

    /// Stop live-view when the Capture tab leaves the screen.
    func stopLiveView() async {
        guard liveViewConsumers > 0 else { return }
        liveViewConsumers -= 1
        guard liveViewConsumers == 0 else { return }
        await endLiveViewSession()
    }

    private func beginLiveViewSession() async {
        guard case .connected = state, let commandConnection else {
            liveViewError = "相机未连接"
            isLiveViewActive = false
            liveViewImage = nil
            return
        }
        guard supportsLiveView else {
            liveViewError = "当前相机不支持实时图传"
            isLiveViewActive = false
            appendLog("[liveview] 相机未声明 StartLiveView/GetLiveViewImage")
            return
        }

        liveViewGeneration &+= 1
        let generation = liveViewGeneration
        liveViewTask?.cancel()
        liveViewTask = nil
        isLiveViewActive = false
        liveViewImage = nil
        appendLog("[liveview] 开始启动实时图传 generation=\(generation)")

        do {
            try await prepareLiveView(on: commandConnection)
            guard generation == liveViewGeneration, liveViewConsumers > 0, case .connected = state else { return }
            isLiveViewActive = true
            liveViewError = nil
            liveViewTask = Task { [weak self] in
                await self?.runLiveViewLoop(generation: generation)
            }
        } catch {
            guard generation == liveViewGeneration else { return }
            isLiveViewActive = false
            liveViewImage = nil
            liveViewError = error.localizedDescription
            appendLog("[liveview] 启动失败 error=\(error.localizedDescription)")
        }
    }

    private func endLiveViewSession() async {
        stopLiveViewInternal(sendEndCommand: true)
    }

    private func stopLiveViewInternal(sendEndCommand: Bool) {
        liveViewGeneration &+= 1
        liveViewTask?.cancel()
        liveViewTask = nil
        isLiveViewActive = false
        liveViewImage = nil
        if !sendEndCommand {
            liveViewError = nil
            return
        }
        guard case .connected = state, let commandConnection, supportsOperation(.endLiveView) else {
            liveViewError = nil
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await self.operation(
                    .endLiveView,
                    parameters: [],
                    dataPhase: nil,
                    on: commandConnection,
                    logStyle: .compact
                )
                self.appendLog("[liveview] EndLiveView code=0x\(String(format: "%04X", response.code))")
            } catch {
                self.appendLog("[liveview] EndLiveView 失败 error=\(error.localizedDescription)")
            }
            if self.liveViewConsumers == 0 {
                self.liveViewError = nil
            }
        }
    }

    private var supportsLiveView: Bool {
        supportsOperation(.startLiveView) && (supportsOperation(.getLiveViewImage) || supportsOperation(.getLiveViewImageEx))
    }

    private func supportsOperation(_ code: PTPOperationCode) -> Bool {
        supportedOperations.contains(code.rawValue)
    }

    private func prepareLiveView(on connection: NWConnection) async throws {
        // Prefer leaving the camera body monitor usable: only enter application mode
        // when StartLiveView is rejected without it.
        var start = try await operation(
            .startLiveView,
            parameters: [],
            dataPhase: nil,
            on: connection,
            logStyle: .compact
        )
        if start.code != PTPResponseCode.ok.rawValue,
           supportsOperation(.changeApplicationMode) {
            appendLog("[liveview] StartLiveView 初次失败 code=0x\(String(format: "%04X", start.code))，尝试 ChangeApplicationMode")
            let mode = try await operation(
                .changeApplicationMode,
                parameters: [1],
                dataPhase: nil,
                on: connection,
                logStyle: .compact
            )
            appendLog("[liveview] ChangeApplicationMode code=0x\(String(format: "%04X", mode.code))")
            start = try await operation(
                .startLiveView,
                parameters: [],
                dataPhase: nil,
                on: connection,
                logStyle: .compact
            )
        }
        guard start.code == PTPResponseCode.ok.rawValue else {
            throw CameraConnectionError.ptpResponse(start.code)
        }
        try await waitUntilDeviceReady(on: connection)
    }

    private func waitUntilDeviceReady(on connection: NWConnection) async throws {
        guard supportsOperation(.deviceReady) else {
            try await Task.sleep(for: .milliseconds(400))
            return
        }
        for attempt in 1...12 {
            if Task.isCancelled { throw CameraConnectionError.connectionCancelled }
            let response = try await operation(
                .deviceReady,
                parameters: [],
                dataPhase: nil,
                on: connection,
                logStyle: .silent
            )
            if response.code == PTPResponseCode.ok.rawValue {
                appendLog("[liveview] DeviceReady OK attempt=\(attempt)")
                return
            }
            if response.code == PTPResponseCode.deviceBusy.rawValue {
                try await Task.sleep(for: .milliseconds(250))
                continue
            }
            appendLog("[liveview] DeviceReady code=0x\(String(format: "%04X", response.code)) attempt=\(attempt)")
            try await Task.sleep(for: .milliseconds(250))
        }
        // Some bodies keep returning busy briefly; still allow frame polling to proceed.
        appendLog("[liveview] DeviceReady 超时，继续尝试拉流")
    }

    private func runLiveViewLoop(generation: Int) async {
        appendLog("[liveview] 拉流循环开始 generation=\(generation)")
        var consecutiveFailures = 0
        while !Task.isCancelled,
              generation == liveViewGeneration,
              liveViewConsumers > 0,
              case .connected = state,
              let commandConnection {
            do {
                if let frame = try await fetchLiveViewFrame(on: commandConnection) {
                    liveViewImage = frame
                    liveViewError = nil
                    consecutiveFailures = 0
                } else {
                    consecutiveFailures += 1
                }
            } catch is CancellationError {
                break
            } catch {
                consecutiveFailures += 1
                if consecutiveFailures == 1 || consecutiveFailures % 20 == 0 {
                    appendLog("[liveview] 拉帧失败 count=\(consecutiveFailures) error=\(error.localizedDescription)")
                }
                if consecutiveFailures >= 40 {
                    liveViewError = error.localizedDescription
                    isLiveViewActive = false
                    break
                }
                try? await Task.sleep(for: .milliseconds(120))
                continue
            }
            // Yield the command channel so gallery/status requests can interleave.
            try? await Task.sleep(for: .milliseconds(33))
        }
        if generation == liveViewGeneration {
            isLiveViewActive = false
        }
        appendLog("[liveview] 拉流循环结束 generation=\(generation)")
    }

    private func fetchLiveViewFrame(on connection: NWConnection) async throws -> UIImage? {
        let preferred: [PTPOperationCode] = supportsOperation(.getLiveViewImage)
            ? [.getLiveViewImage, .getLiveViewImageEx]
            : [.getLiveViewImageEx, .getLiveViewImage]
        var lastCode: UInt16 = 0
        for code in preferred where supportsOperation(code) || code == .getLiveViewImage {
            // Always allow 0x9203 attempt even if DeviceInfo omitted it; some bodies still answer.
            let response = try await operation(
                code,
                parameters: [],
                dataPhase: .receive,
                on: connection,
                logStyle: .silent
            )
            lastCode = response.code
            if response.code == PTPResponseCode.deviceBusy.rawValue {
                try await Task.sleep(for: .milliseconds(40))
                return nil
            }
            guard response.code == PTPResponseCode.ok.rawValue, let data = response.data, data.count > 64 else {
                continue
            }
            if let image = decodeLiveViewJPEG(from: data) {
                return image
            }
            appendLog("[liveview] \(code.debugName) 返回数据无法解码 bytes=\(data.count)")
        }
        if lastCode != 0, lastCode != PTPResponseCode.ok.rawValue, lastCode != PTPResponseCode.deviceBusy.rawValue {
            throw CameraConnectionError.ptpResponse(lastCode)
        }
        return nil
    }

    private func decodeLiveViewJPEG(from data: Data) -> UIImage? {
        if let image = UIImage(data: data) {
            return image
        }
        guard let jpeg = extractJPEGPayload(from: data) else { return nil }
        return UIImage(data: jpeg)
    }

    private func extractJPEGPayload(from data: Data) -> Data? {
        guard let soi = data.range(of: Data([0xFF, 0xD8])) else { return nil }
        if let eoi = data.range(of: Data([0xFF, 0xD9]), options: [], in: soi.lowerBound..<data.endIndex) {
            return Data(data[soi.lowerBound..<eoi.upperBound])
        }
        return Data(data[soi.lowerBound...])
    }

    private func operation(
        _ code: PTPOperationCode,
        parameters: [UInt32],
        dataPhase: DataPhase?,
        on connection: NWConnection,
        logStyle: OperationLogStyle = .verbose,
        priority: OperationPriority = .foreground,
        timeout: Duration? = nil
    ) async throws -> PTPResponse {
        await acquireOperationSlot(priority: priority)

        let currentTransactionID = max(transactionID &+ 1, 1)
        transactionID = currentTransactionID
        activeOperationTransactionID = currentTransactionID
        let timeoutTask = timeout.map { timeout in
            Task { [weak self, weak connection] in
                guard let self, let connection else { return }
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                guard self.activeOperationTransactionID == currentTransactionID else { return }
                self.appendLog(
                    "[command] Operation timeout name=\(code.debugName) " +
                        "transaction=\(currentTransactionID)，发送 CancelTransaction"
                )
                try? await self.send(
                    ptpIPPacket(
                        type: .cancelTransaction,
                        payload: uint32Data(currentTransactionID)
                    ),
                    on: connection,
                    logStyle: .compact
                )
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
                guard self.activeOperationTransactionID == currentTransactionID else { return }
                self.appendLog(
                    "[command] CancelTransaction未收到响应 name=\(code.debugName) " +
                        "transaction=\(currentTransactionID)，重建连接"
                )
                connection.cancel()
                self.beginAutomaticReconnect(reason: "\(code.debugName) 超时")
            }
        }
        defer {
            timeoutTask?.cancel()
            if activeOperationTransactionID == currentTransactionID {
                activeOperationTransactionID = nil
            }
            releaseOperationSlot()
        }

        var operationPayload = Data()
        let dataPhaseValue: UInt32
        switch dataPhase {
        case nil:
            dataPhaseValue = 0x00000001
        case .receive:
            dataPhaseValue = 0x00000001
        case .send:
            dataPhaseValue = 0x00000002
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

        if let dataPhase, case .send(let outgoingData) = dataPhase {
            let startDataPayload =
                uint32Data(currentTransactionID) +
                uint32Data(UInt32(outgoingData.count)) +
                uint32Data(0)
            try await send(
                ptpIPPacket(type: .startData, payload: startDataPayload),
                on: connection,
                logStyle: logStyle
            )

            let bytes = Array(outgoingData)
            var offset = 0
            while offset < bytes.count {
                let end = min(offset + 65_536, bytes.count)
                let packetType: PTPIPPacketType = end == bytes.count ? .endData : .data
                let payload = uint32Data(currentTransactionID) + Data(bytes[offset..<end])
                try await send(
                    ptpIPPacket(type: packetType, payload: payload),
                    on: connection,
                    logStyle: logStyle
                )
                offset = end
            }
        }

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
                let responseParameters = stride(from: 6, through: packet.payload.count - 4, by: 4).map {
                    packet.payload.uint32(at: $0)
                }
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
                let responseData: Data?
                if let dataPhase, case .receive = dataPhase {
                    responseData = receivedData
                } else {
                    responseData = nil
                }
                return PTPResponse(
                    code: responseCode,
                    data: responseData,
                    parameters: responseParameters
                )
            default:
                if logStyle != .silent {
                    appendLog("[command] 忽略未预期包 type=\(packet.typeName)")
                }
                continue
            }
        }
    }

    private func start(_ connection: NWConnection) async throws {
        let generation = connectionGeneration
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    Task { @MainActor in
                        self.appendLog("NWConnection state=ready")
                    }
                    connection.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error):
                    Task { @MainActor in
                        self.appendLog("NWConnection state=failed error=\(String(reflecting: error))")
                        self.handleTransportFailure(connection, generation: generation, reason: error.localizedDescription)
                    }
                    connection.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                case .cancelled:
                    Task { @MainActor in
                        self.appendLog("NWConnection state=cancelled")
                        self.handleTransportFailure(connection, generation: generation, reason: "连接已取消")
                    }
                    connection.stateUpdateHandler = nil
                    continuation.resume(throwing: CameraConnectionError.connectionCancelled)
                default:
                    break
                }
            }
            connection.start(queue: .main)
        }
        monitorConnection(connection)
    }

    private func monitorConnection(_ connection: NWConnection) {
        let generation = connectionGeneration
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                Task { @MainActor in self.appendLog("NWConnection state=ready") }
            case .failed(let error):
                Task { @MainActor in
                    self.appendLog("NWConnection state=failed error=\(String(reflecting: error))")
                    self.handleTransportFailure(connection, generation: generation, reason: error.localizedDescription)
                }
            case .cancelled:
                Task { @MainActor in
                    self.appendLog("NWConnection state=cancelled")
                    self.handleTransportFailure(connection, generation: generation, reason: "连接已取消")
                }
            default:
                break
            }
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
            noteTransportError(connection, reason: error.localizedDescription)
            throw error
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
                noteTransportError(connection, reason: error.localizedDescription)
                throw error
            }
            collected.append(chunk)
        }
        return collected
    }

    private func disconnectConnections() {
        connectionGeneration = UUID()
        commandConnection?.cancel()
        eventConnection?.cancel()
        commandConnection = nil
        eventConnection = nil
        connectionNumber = nil
    }

    private func acquireOperationSlot(priority: OperationPriority) async {
        if !isOperationBusy {
            isOperationBusy = true
            return
        }
        await withCheckedContinuation { continuation in
            switch priority {
            case .foreground:
                foregroundOperationWaiters.append(continuation)
            case .background:
                backgroundOperationWaiters.append(continuation)
            }
        }
    }

    private func releaseOperationSlot() {
        if let next = dequeueForegroundOperationWaiter() {
            next.resume()
        } else if let next = dequeueBackgroundOperationWaiter() {
            next.resume()
        } else {
            isOperationBusy = false
        }
    }

    private func dequeueForegroundOperationWaiter() -> CheckedContinuation<Void, Never>? {
        guard foregroundOperationWaiterIndex < foregroundOperationWaiters.count else { return nil }
        let waiter = foregroundOperationWaiters[foregroundOperationWaiterIndex]
        foregroundOperationWaiterIndex += 1
        if foregroundOperationWaiterIndex == foregroundOperationWaiters.count {
            foregroundOperationWaiters.removeAll(keepingCapacity: true)
            foregroundOperationWaiterIndex = 0
        }
        return waiter
    }

    private func dequeueBackgroundOperationWaiter() -> CheckedContinuation<Void, Never>? {
        guard backgroundOperationWaiterIndex < backgroundOperationWaiters.count else { return nil }
        let waiter = backgroundOperationWaiters[backgroundOperationWaiterIndex]
        backgroundOperationWaiterIndex += 1
        if backgroundOperationWaiterIndex == backgroundOperationWaiters.count {
            backgroundOperationWaiters.removeAll(keepingCapacity: true)
            backgroundOperationWaiterIndex = 0
        }
        return waiter
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
            // Most PTP cameras support filtering handles by Association (folder) format.
            // This avoids fetching ObjectInfo for every photo before the first grid can appear.
            let filteredFolders = try? await fetchObjectHandles(
                storageID: storageID,
                objectFormat: 0x3001,
                parent: 0xffffffff,
                on: connection
            )
            let usesAssociationFilter = filteredFolders?.isEmpty == false
            var seedHandles: [UInt32] = []
            if usesAssociationFilter {
                seedHandles = filteredFolders ?? []
                appendLog(
                    "[图库] 使用目录过滤 storageID=0x\(String(format: "%08X", storageID)) folders=\(seedHandles.count)"
                )
            } else if let root = try? await fetchObjectHandles(
                storageID: storageID,
                objectFormat: 0,
                parent: 0xffffffff,
                on: connection
            ) {
                appendLog(
                    "[图库] 目录过滤不可用，回退根目录扫描 storageID=0x\(String(format: "%08X", storageID)) count=\(root.count)"
                )
                seedHandles = root
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
                            objectFormat: usesAssociationFilter ? 0x3001 : 0,
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

    private func fetchNikonObjectsMetadata(
        in directory: GalleryDirectory,
        on connection: NWConnection
    ) async throws -> NikonObjectsMetadata {
        guard !directory.isSyntheticRoot else {
            throw NikonMetadataLoadError.allStrategiesFailed(
                responseCode: nil,
                reason: "合成根目录没有可用于 Nikon 指令的真实 association handle"
            )
        }

        let pathPrefix = directory.path.isEmpty ? "" : directory.path + "/"
        let descendants = galleryDirectories
            .filter {
                !$0.isSyntheticRoot
                    && $0.storageID == directory.storageID
                    && $0.id != directory.id
                    && $0.path.hasPrefix(pathPrefix)
            }
            .sorted { lhs, rhs in
                let lhsDepth = lhs.path.split(separator: "/").count
                let rhsDepth = rhs.path.split(separator: "/").count
                if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
                return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
            }
        let targets = [directory] + descendants
        appendLog(
            "[图库] GetObjectsMetaData目录范围 selected=\(directory.path) " +
                "targets=\(targets.count) descendants=\(descendants.count)"
        )

        var lastFailure = "没有可用响应"
        var lastResponseCode: UInt16?
        var firstHeader: UInt32?
        var recordsByHandle: [UInt32: NikonObjectMetadata] = [:]
        var hadFailure = false

        for (index, target) in targets.enumerated() {
            let strategyName = index == 0 ? "selected-directory" : "descendant-directory"
            let parameters = [directory.storageID, UInt32(0), target.handle]
            let parameterText = parameters
                .map { String(format: "0x%08X", $0) }
                .joined(separator: ",")
            appendLog(
                "[图库] GetObjectsMetaData策略=\(strategyName) path=\(target.path) " +
                    "parameters=[\(parameterText)]"
            )

            let response: PTPResponse
            do {
                response = try await operation(
                    .getObjectsMetadata,
                    parameters: parameters,
                    dataPhase: .receive,
                    on: connection,
                    logStyle: .compact,
                    timeout: .seconds(8)
                )
            } catch {
                hadFailure = true
                lastFailure = "策略 \(strategyName) path=\(target.path) 传输异常：\(error.localizedDescription)"
                appendLog("[图库] GetObjectsMetaData策略失败 strategy=\(strategyName) reason=\(lastFailure)")
                if case .ready = connection.state {
                    continue
                }
                throw NikonMetadataLoadError.allStrategiesFailed(
                    responseCode: lastResponseCode,
                    reason: lastFailure
                )
            }

            lastResponseCode = response.code
            let byteCount = response.data?.count ?? 0
            appendLog(
                "[图库] GetObjectsMetaData响应 strategy=\(strategyName) path=\(target.path) " +
                    "code=0x\(String(format: "%04X", response.code)) bytes=\(byteCount)"
            )
            guard response.code == PTPResponseCode.ok.rawValue else {
                hadFailure = true
                lastFailure = "策略 \(strategyName) path=\(target.path) 返回码 0x\(String(format: "%04X", response.code))"
                continue
            }
            guard let data = response.data, !data.isEmpty else {
                hadFailure = true
                lastFailure = "策略 \(strategyName) path=\(target.path) 返回空数据"
                continue
            }

            let parseStarted = DispatchTime.now().uptimeNanoseconds
            do {
                let metadata = try await Task.detached(priority: .userInitiated) {
                    try NikonObjectsMetadataParser.parse(data)
                }.value
                let elapsedNanoseconds = DispatchTime.now().uptimeNanoseconds - parseStarted
                let elapsedMilliseconds = elapsedNanoseconds / 1_000_000
                appendLog(
                    "[图库] GetObjectsMetaData解析 bytes=\(data.count) records=\(metadata.records.count) " +
                        "elapsedMs=\(elapsedMilliseconds) strategy=\(strategyName) path=\(target.path)"
                )
                if metadata.records.isEmpty {
                    lastFailure = "策略 \(strategyName) path=\(target.path) 返回 0 条记录"
                    continue
                }
                if firstHeader == nil {
                    firstHeader = metadata.header
                }
                for record in metadata.records {
                    recordsByHandle[record.handle] = record
                }
            } catch {
                hadFailure = true
                lastFailure = "策略 \(strategyName) path=\(target.path) 数据格式异常：\(error)"
                appendLog("[图库] GetObjectsMetaData解析失败 strategy=\(strategyName) reason=\(error)")
            }
        }

        if !hadFailure, !recordsByHandle.isEmpty {
            let records = await Task.detached(priority: .userInitiated) {
                NikonObjectsMetadataParser.sortedRecords(Array(recordsByHandle.values))
            }.value
            appendLog(
                "[图库] GetObjectsMetaData目录合并完成 targets=\(targets.count) " +
                    "objects=\(records.count)"
            )
            return NikonObjectsMetadata(header: firstHeader ?? 0, records: records)
        }

        if hadFailure, !recordsByHandle.isEmpty {
            lastFailure += "；为避免发布不完整列表，丢弃已取得的 \(recordsByHandle.count) 条记录"
        } else if !hadFailure {
            lastFailure = "选中目录及其 \(descendants.count) 个后代目录均返回 0 条记录"
        }

        throw NikonMetadataLoadError.allStrategiesFailed(
            responseCode: lastResponseCode,
            reason: lastFailure
        )
    }

    nonisolated private static func makeSkeletonItem(from record: NikonObjectMetadata) -> GalleryItem {
        GalleryItem(
            id: record.handle,
            filename: "",
            objectFormat: 0,
            fileSize: 0,
            isVideo: false,
            captureDate: record.captureDate,
            rawHandle: nil,
            rawFilename: nil,
            rawFileSize: nil,
            jpegHandle: nil,
            jpegFilename: nil,
            jpegFileSize: nil
        )
    }

    private func enrichMetadataGallery(
        _ metadata: NikonObjectsMetadata,
        in directory: GalleryDirectory,
        on connection: NWConnection,
        generation: Int
    ) async {
        var resolved: [UInt32: GalleryItem] = [:]
        var excludedHandles = Set<UInt32>()
        var failedInfo = 0
        var pendingChanges = 0
        var lastPublish = Date()

        for (index, record) in metadata.records.enumerated() {
            guard isCurrentGalleryLoad(generation, directoryID: directory.id) else { return }
            do {
                if let info = try await fetchObjectInfo(
                    handle: record.handle,
                    on: connection,
                    priority: .background
                ) {
                    if isAssociationObject(objectFormat: info.objectFormat)
                        || !isGalleryMedia(objectFormat: info.objectFormat, filename: info.filename)
                    {
                        excludedHandles.insert(record.handle)
                    } else {
                        let isVideo = isVideoMedia(objectFormat: info.objectFormat, filename: info.filename)
                        let isRAW = !isVideo && isRAWMedia(objectFormat: info.objectFormat, filename: info.filename)
                        resolved[record.handle] = GalleryItem(
                            id: record.handle,
                            filename: info.filename,
                            objectFormat: info.objectFormat,
                            fileSize: info.fileSize,
                            isVideo: isVideo,
                            captureDate: record.captureDate ?? info.captureDate ?? info.modificationDate,
                            rawHandle: isRAW ? record.handle : nil,
                            rawFilename: isRAW ? info.filename : nil,
                            rawFileSize: isRAW ? info.fileSize : nil,
                            jpegHandle: !isVideo && !isRAW ? record.handle : nil,
                            jpegFilename: !isVideo && !isRAW ? info.filename : nil,
                            jpegFileSize: !isVideo && !isRAW ? info.fileSize : nil
                        )
                    }
                } else {
                    failedInfo += 1
                }
            } catch {
                failedInfo += 1
                appendLog(
                    "[图库] 后台 ObjectInfo 跳过 handle=0x\(String(format: "%08X", record.handle)) " +
                        "error=\(error.localizedDescription)"
                )
            }

            pendingChanges += 1
            let isLast = index == metadata.records.count - 1
            let shouldPublish = isLast || pendingChanges >= 16 || Date().timeIntervalSince(lastPublish) >= 0.35
            if shouldPublish {
                let records = metadata.records
                let resolvedSnapshot = resolved
                let excludedSnapshot = excludedHandles
                let published = await Task.detached(priority: .utility) {
                    Self.buildEnrichedGalleryItems(
                        records: records,
                        resolved: resolvedSnapshot,
                        excludedHandles: excludedSnapshot
                    )
                }.value
                guard isCurrentGalleryLoad(generation, directoryID: directory.id) else { return }
                if published != galleryItems {
                    galleryItems = published
                }
                pendingChanges = 0
                lastPublish = Date()
            }

            await Task.yield()
        }

        guard isCurrentGalleryLoad(generation, directoryID: directory.id) else { return }
        let photos = galleryItems.filter { !$0.isVideo }.count
        let videos = galleryItems.filter(\.isVideo).count
        appendLog(
            "[图库] GetObjectsMetaData补充完成 dir=\(directory.pickerTitle) " +
                "objects=\(galleryItems.count) photos=\(photos) videos=\(videos) infoErrors=\(failedInfo)"
        )
    }

    nonisolated private static func buildEnrichedGalleryItems(
        records: [NikonObjectMetadata],
        resolved: [UInt32: GalleryItem],
        excludedHandles: Set<UInt32>
    ) -> [GalleryItem] {
        let candidates = records.compactMap { record -> GalleryItem? in
            if excludedHandles.contains(record.handle) { return nil }
            return resolved[record.handle] ?? makeSkeletonItem(from: record)
        }
        return sortedGalleryItems(mergePairedPhotos(candidates))
    }

    private func loadMediaItems(
        in directory: GalleryDirectory,
        on connection: NWConnection,
        generation: Int
    ) async throws -> [GalleryItem] {
        let rootHandles = try await fetchObjectHandles(
            storageID: directory.storageID,
            objectFormat: 0,
            parent: directory.isSyntheticRoot ? 0xffffffff : directory.handle,
            on: connection
        )

        appendLog("[图库] 读取目录内容 dir=\(directory.pickerTitle) children=\(rootHandles.count)")

        var items: [GalleryItem] = []
        var skippedNonMedia = 0
        var skippedErrors = 0
        var visited = Set<UInt32>()
        var queue = rootHandles
        var queueIndex = 0
        var processed = 0
        var itemsSincePublish = 0
        var lastPublish = Date()

        while queueIndex < queue.count {
            guard isCurrentGalleryLoad(generation, directoryID: directory.id) else {
                throw CancellationError()
            }
            let handle = queue[queueIndex]
            queueIndex += 1
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
                let isRAW = !isVideo && isRAWMedia(objectFormat: info.objectFormat, filename: info.filename)
                items.append(
                    GalleryItem(
                        id: handle,
                        filename: info.filename,
                        objectFormat: info.objectFormat,
                        fileSize: info.fileSize,
                        isVideo: isVideo,
                        captureDate: info.captureDate ?? info.modificationDate,
                        rawHandle: isRAW ? handle : nil,
                        rawFilename: isRAW ? info.filename : nil,
                        rawFileSize: isRAW ? info.fileSize : nil,
                        jpegHandle: !isVideo && !isRAW ? handle : nil,
                        jpegFilename: !isVideo && !isRAW ? info.filename : nil,
                        jpegFileSize: !isVideo && !isRAW ? info.fileSize : nil
                    )
                )
                itemsSincePublish += 1
            } catch {
                skippedErrors += 1
                appendLog(
                    "[图库] ObjectInfo 跳过 handle=0x\(String(format: "%08X", handle)) " +
                        "error=\(error.localizedDescription)"
                )
            }

            let isLast = queueIndex >= queue.count
            let shouldPublish = !items.isEmpty
                && (isLast || itemsSincePublish >= 24 || Date().timeIntervalSince(lastPublish) >= 0.4)
            if shouldPublish {
                let snapshot = items
                let partialItems = await Task.detached(priority: .utility) {
                    Self.sortedGalleryItems(Self.mergePairedPhotos(snapshot))
                }.value
                if isCurrentGalleryLoad(generation, directoryID: directory.id), partialItems != galleryItems {
                    galleryItems = partialItems
                }
                itemsSincePublish = 0
                lastPublish = Date()
            }

            if processed % 25 == 0 || isLast {
                appendLog(
                    "[图库] 目录解析进度 dir=\(directory.pickerTitle) processed=\(processed) pending=\(queue.count - queueIndex) " +
                        "media=\(items.count)"
                )
            }

            await Task.yield()
        }

        items = await Task.detached(priority: .utility) {
            Self.sortedGalleryItems(Self.mergePairedPhotos(items))
        }.value

        appendLog(
            "[图库] 目录解析结束 dir=\(directory.pickerTitle) media=\(items.count) " +
                "skippedNonMedia=\(skippedNonMedia) errors=\(skippedErrors)"
        )
        return items
    }

    nonisolated private static func sortedGalleryItems(_ items: [GalleryItem]) -> [GalleryItem] {
        items.sorted { lhs, rhs in
            switch (lhs.captureDate, rhs.captureDate) {
            case (let l?, let r?):
                if l != r { return l > r }
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                break
            }
            return lhs.id > rhs.id
        }
    }

    nonisolated private static func mergePairedPhotos(_ sourceItems: [GalleryItem]) -> [GalleryItem] {
        var merged: [GalleryItem] = []
        var photoIndexes: [String: Int] = [:]

        for item in sourceItems {
            guard !item.isVideo else {
                merged.append(item)
                continue
            }

            let hasRAW = item.rawHandle != nil
            let hasJPEG = item.jpegHandle != nil
            guard hasRAW != hasJPEG else {
                merged.append(item)
                continue
            }

            let key = photoPairKey(for: item.filename)
            if let index = photoIndexes[key] {
                merged[index] = combinePhotoItems(merged[index], item)
            } else {
                photoIndexes[key] = merged.count
                merged.append(item)
            }
        }

        return merged
    }

    nonisolated private static func combinePhotoItems(_ lhs: GalleryItem, _ rhs: GalleryItem) -> GalleryItem {
        let rawItem = lhs.rawHandle != nil ? lhs : rhs
        let jpegItem = lhs.jpegHandle != nil ? lhs : rhs
        let captureDate = lhs.captureDate ?? rhs.captureDate

        return GalleryItem(
            id: min(lhs.id, rhs.id),
            filename: jpegItem.jpegFilename ?? rawItem.rawFilename ?? lhs.filename,
            objectFormat: jpegItem.jpegHandle != nil ? jpegItem.objectFormat : rawItem.objectFormat,
            fileSize: (rawItem.rawFileSize ?? 0) + (jpegItem.jpegFileSize ?? 0),
            isVideo: false,
            captureDate: captureDate,
            rawHandle: rawItem.rawHandle,
            rawFilename: rawItem.rawFilename,
            rawFileSize: rawItem.rawFileSize,
            jpegHandle: jpegItem.jpegHandle,
            jpegFilename: jpegItem.jpegFilename,
            jpegFileSize: jpegItem.jpegFileSize
        )
    }

    nonisolated private static func photoPairKey(for filename: String) -> String {
        let base = (filename as NSString).deletingPathExtension
        return base.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
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
        let present = ids.filter { ($0 & 0x0000ffff) != 0 }
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

    private struct ParsedObjectInfo: Sendable {
        var objectFormat: UInt16
        var fileSize: UInt64
        var filename: String
        var captureDate: Date?
        var modificationDate: Date?
    }

    private func fetchObjectInfo(
        handle: UInt32,
        on connection: NWConnection,
        priority: OperationPriority = .foreground
    ) async throws -> ParsedObjectInfo? {
        let response = try await operation(
            .getObjectInfo,
            parameters: [handle],
            dataPhase: .receive,
            on: connection,
            logStyle: .silent,
            priority: priority
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
        case 0x3801, 0x3802, 0x3804, 0x3808, 0x380d, 0x3811, 0xb802, 0xb80a:
            return true
        default:
            break
        }
        let ext = fileExtension(filename)
        return ["JPG", "JPEG", "HEIC", "HEIF", "TIF", "TIFF", "PNG", "NEF", "NRW", "DNG", "CR2", "CR3", "ARW"].contains(ext)
    }

    private func isRAWMedia(objectFormat: UInt16, filename: String) -> Bool {
        if objectFormat == 0xB802 || objectFormat == 0xB80A {
            return true
        }
        let ext = fileExtension(filename)
        return ["NEF", "NRW", "DNG", "CR2", "CR3", "ARW", "RAF", "ORF", "RW2", "RWL", "SRW", "PEF", "3FR", "X3F"].contains(ext)
    }

    private func isVideoMedia(objectFormat: UInt16, filename: String) -> Bool {
        switch objectFormat {
        case 0x3008, 0x3009, 0x300a, 0x300b, 0x300c, 0x300d, 0xb982, 0xb984:
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
           let value = data.first
        {
            status.batteryLevel = min(Int(value), 100)
        }

        if let storageIDs = try? await operation(.getStorageIDs, parameters: [], dataPhase: .receive, on: connection),
           storageIDs.code == PTPResponseCode.ok.rawValue,
           let data = storageIDs.data,
           data.count >= 4
        {
            let count = Int(data.uint32(at: 0))
            if count > 0, data.count >= 8 {
                let storageID = data.uint32(at: 4)
                if let storageInfo = try? await operation(.getStorageInfo, parameters: [storageID], dataPhase: .receive, on: connection),
                   storageInfo.code == PTPResponseCode.ok.rawValue,
                   let storageData = storageInfo.data,
                   storageData.count >= 27
                {
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
        if let response = try? await operation(.getDevicePropValue, parameters: [0xd0e0], dataPhase: .receive, on: connection),
           response.code == PTPResponseCode.ok.rawValue,
           let data = response.data,
           let value = readIntegerValue(from: data)
        {
            info.lensID = UInt16(clamping: value)
            appendLog("镜头 LensID=0x\(String(format: "%04X", info.lensID ?? 0)) raw=\(value)")
        }

        if let response = try? await operation(.getDevicePropValue, parameters: [0xd0e2], dataPhase: .receive, on: connection),
           response.code == PTPResponseCode.ok.rawValue,
           let data = response.data,
           let value = readIntegerValue(from: data)
        {
            info.lensType = UInt32(clamping: value)
            appendLog("镜头 LensType=\(value)")
        }

        if let response = try? await operation(.getDevicePropValue, parameters: [0xd0e3], dataPhase: .receive, on: connection),
           response.code == PTPResponseCode.ok.rawValue,
           let data = response.data,
           let value = readIntegerValue(from: data)
        {
            info.minFocalLengthMM = Double(value) / 100.0
        }

        if let response = try? await operation(.getDevicePropValue, parameters: [0xd0e4], dataPhase: .receive, on: connection),
           response.code == PTPResponseCode.ok.rawValue,
           let data = response.data,
           let value = readIntegerValue(from: data)
        {
            info.maxFocalLengthMM = Double(value) / 100.0
        }

        if let response = try? await operation(.getDevicePropValue, parameters: [0xd0e5], dataPhase: .receive, on: connection),
           response.code == PTPResponseCode.ok.rawValue,
           let data = response.data,
           let value = readIntegerValue(from: data)
        {
            info.maxApertureAtMinFocal = Double(value) / 100.0
        }

        if let response = try? await operation(.getDevicePropValue, parameters: [0xd0e6], dataPhase: .receive, on: connection),
           response.code == PTPResponseCode.ok.rawValue,
           let data = response.data,
           let value = readIntegerValue(from: data)
        {
            info.maxApertureAtMaxFocal = Double(value) / 100.0
        }

        if let response = try? await operation(.getDevicePropValue, parameters: [0x5008], dataPhase: .receive, on: connection),
           response.code == PTPResponseCode.ok.rawValue,
           let data = response.data,
           let value = readIntegerValue(from: data)
        {
            info.currentFocalLengthMM = Double(value) / 100.0
        }

        if let response = try? await operation(.getDevicePropValue, parameters: [0x5007], dataPhase: .receive, on: connection),
           response.code == PTPResponseCode.ok.rawValue,
           let data = response.data,
           let value = readIntegerValue(from: data)
        {
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

    private func readDeviceProperty(
        _ propertyCode: UInt16,
        on connection: NWConnection
    ) async -> UInt64? {
        guard let response = try? await operation(
            .getDevicePropValue,
            parameters: [UInt32(propertyCode)],
            dataPhase: .receive,
            on: connection,
            logStyle: .silent,
            timeout: .seconds(4)
        ),
        response.code == PTPResponseCode.ok.rawValue,
        let data = response.data else {
            return nil
        }
        return readIntegerValue(from: data)
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
              data.uint16(at: nameEnd) == 0
        else {
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
        let operationList = try readUInt16Array(in: data, at: offset)
        supportedOperations = Set(operationList.values)
        supportsPreviewImage = supportedOperations.contains(PTPOperationCode.getPreviewImage.rawValue)
        let supportsObjectsMetadata = supportedOperations.contains(PTPOperationCode.getObjectsMetadata.rawValue)
        let liveViewOps = [
            ("StartLiveView", PTPOperationCode.startLiveView.rawValue),
            ("EndLiveView", PTPOperationCode.endLiveView.rawValue),
            ("GetLiveViewImg", PTPOperationCode.getLiveViewImage.rawValue),
            ("GetLiveViewImageEx", PTPOperationCode.getLiveViewImageEx.rawValue),
            ("DeviceReady", PTPOperationCode.deviceReady.rawValue),
            ("ChangeApplicationMode", PTPOperationCode.changeApplicationMode.rawValue)
        ].filter { supportedOperations.contains($0.1) }.map(\.0)
        appendLog(
            "DeviceInfo Operations count=\(operationList.values.count) previewImage=\(supportsPreviewImage) " +
                "getObjectsMetaData=\(supportsObjectsMetadata) " +
                "liveView=[\(liveViewOps.joined(separator: ","))] offset=\(operationList.nextOffset)"
        )
        if supportsObjectsMetadata {
            appendLog("[图库] 相机公布 GetObjectsMetaData(0x9434)")
            appendLog("[图库] GetObjectsMetaData可用")
        } else {
            appendLog("[图库] 相机未公布 GetObjectsMetaData(0x9434)")
        }
        offset = operationList.nextOffset
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

    private func readUInt16Array(in data: Data, at offset: Int) throws -> (values: [UInt16], nextOffset: Int) {
        guard data.count >= offset + 4 else {
            throw CameraConnectionError.malformedPacket
        }
        let count = Int(data.uint32(at: offset))
        let nextOffset = offset + 4 + count * 2
        guard nextOffset <= data.count else {
            throw CameraConnectionError.malformedPacket
        }
        var values: [UInt16] = []
        values.reserveCapacity(count)
        for index in 0..<count {
            values.append(data.uint16(at: offset + 4 + index * 2))
        }
        return (values, nextOffset)
    }

    private func skipUInt16Array(in data: Data, at offset: Int) throws -> Int {
        try readUInt16Array(in: data, at: offset).nextOffset
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
    case send(Data)
}

private enum OperationLogStyle {
    /// Connection setup: include packet hex dumps.
    case verbose
    /// One-line packet size logs without hex payloads.
    case compact
    /// Suppress routine transport logs; caller records progress/errors.
    case silent
}

private enum OperationPriority {
    case foreground
    case background
}

private struct PTPResponse {
    let code: UInt16
    let data: Data?
    let parameters: [UInt32]

    init(code: UInt16, data: Data?, parameters: [UInt32] = []) {
        self.code = code
        self.data = data
        self.parameters = parameters
    }
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

private enum PTPOperationCode: UInt16 {
    case getDeviceInfo = 0x1001
    case openSession = 0x1002
    case getStorageIDs = 0x1004
    case getStorageInfo = 0x1005
    case getNumObjects = 0x1006
    case getObjectHandles = 0x1007
    case getObjectInfo = 0x1008
    case getObject = 0x1009
    case getThumb = 0x100a
    case getPartialObject = 0x101b
    case getDevicePropValue = 0x1015
    case setDevicePropValue = 0x1016
    case getObjectPropValue = 0x9803
    case deviceReady = 0x90c8
    case getPreviewImage = 0x9200
    case startLiveView = 0x9201
    case endLiveView = 0x9202
    case getLiveViewImage = 0x9203
    case initiateCaptureRecInMedia = 0x9207
    case getLiveViewImageEx = 0x9428
    case getObjectsMetadata = 0x9434
    case changeApplicationMode = 0x9435

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
        case .getPartialObject: return "GetPartialObject"
        case .getDevicePropValue: return "GetDevicePropValue"
        case .setDevicePropValue: return "SetDevicePropValue"
        case .getObjectPropValue: return "GetObjectPropValue"
        case .deviceReady: return "DeviceReady"
        case .getPreviewImage: return "GetPreviewImg"
        case .startLiveView: return "StartLiveView"
        case .endLiveView: return "EndLiveView"
        case .getLiveViewImage: return "GetLiveViewImg"
        case .initiateCaptureRecInMedia: return "InitiateCaptureRecInMedia"
        case .getLiveViewImageEx: return "GetLiveViewImageEx"
        case .getObjectsMetadata: return "GetObjectsMetaData"
        case .changeApplicationMode: return "ChangeApplicationMode"
        }
    }
}

private enum PTPResponseCode: UInt16 {
    case ok = 0x2001
    case deviceBusy = 0x2019
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
            switch code {
            case 0x200A:
                return "当前相机或拍摄模式不支持该参数。"
            case 0x2019:
                return "相机正忙，请稍后重试。"
            case 0x201A:
                return "相机拒绝修改该参数。"
            default:
                return String(format: "相机拒绝了请求（0x%04X）。", code)
            }
        case .initFailed(let code):
            return String(format: "相机拒绝了 PTP/IP 初始化（失败码 0x%08X）。", code)
        }
    }
}

private enum NikonMetadataLoadError: LocalizedError {
    case allStrategiesFailed(responseCode: UInt16?, reason: String)

    var errorDescription: String? {
        switch self {
        case .allStrategiesFailed(let responseCode, let reason):
            if let responseCode {
                return "全部参数策略失败，最后返回码 0x\(String(format: "%04X", responseCode))：\(reason)"
            }
            return "全部参数策略失败：\(reason)"
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
