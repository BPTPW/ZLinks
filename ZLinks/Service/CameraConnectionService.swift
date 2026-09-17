//
//  CameraConnectionService.swift
//  ZLinks
//

import Combine
import Foundation
import ImageIO
import Network
import UIKit

enum LiveViewRefreshInterval: String, CaseIterable {
    case hz60
    case hz30
    case hz10
    case hz5
    case hz1
    case seconds2
    case seconds3
    case seconds5

    static let defaultValue: Self = .hz30

    var title: String {
        switch self {
        case .hz60: return "60Hz"
        case .hz30: return "30Hz"
        case .hz10: return "10Hz"
        case .hz5: return "5Hz"
        case .hz1: return "1Hz"
        case .seconds2: return "2s"
        case .seconds3: return "3s"
        case .seconds5: return "5s"
        }
    }

    var duration: Duration {
        switch self {
        case .hz60: return .nanoseconds(16_666_667)
        case .hz30: return .nanoseconds(33_333_333)
        case .hz10: return .milliseconds(100)
        case .hz5: return .milliseconds(200)
        case .hz1: return .seconds(1)
        case .seconds2: return .seconds(2)
        case .seconds3: return .seconds(3)
        case .seconds5: return .seconds(5)
        }
    }
}

struct LiveViewFocusPoint: Equatable {
    /// Position and frame size normalized to the currently displayed live-view crop.
    let position: CGPoint
    let frameSize: CGSize
}

struct NikonLiveViewFocusMetadata: Equatable {
    let wholeSize: CGSize
    let displayAreaSize: CGSize
    let displayCenter: CGPoint
    let focusFrameSize: CGSize
    let focusFrameCenter: CGPoint
    let isAFDrivingEnabled: Bool

    init(
        wholeSize: CGSize,
        displayAreaSize: CGSize,
        displayCenter: CGPoint,
        focusFrameSize: CGSize,
        focusFrameCenter: CGPoint,
        isAFDrivingEnabled: Bool
    ) {
        self.wholeSize = wholeSize
        self.displayAreaSize = displayAreaSize
        self.displayCenter = displayCenter
        self.focusFrameSize = focusFrameSize
        self.focusFrameCenter = focusFrameCenter
        self.isAFDrivingEnabled = isAFDrivingEnabled
    }

    var isFocusAreaChangeable: Bool {
        isAFDrivingEnabled
            && wholeSize.width > 0
            && wholeSize.height > 0
            && displayAreaSize.width > 0
            && displayAreaSize.height > 0
            && focusFrameSize.width > 0
            && focusFrameSize.height > 0
            && focusFrameSize.width <= wholeSize.width
            && focusFrameSize.height <= wholeSize.height
    }

    var displayedFocusPoint: LiveViewFocusPoint? {
        guard displayAreaSize.width > 0,
              displayAreaSize.height > 0,
              focusFrameSize.width > 0,
              focusFrameSize.height > 0
        else { return nil }

        let origin = CGPoint(
            x: displayCenter.x - displayAreaSize.width / 2,
            y: displayCenter.y - displayAreaSize.height / 2
        )
        let position = CGPoint(
            x: (focusFrameCenter.x - origin.x) / displayAreaSize.width,
            y: (focusFrameCenter.y - origin.y) / displayAreaSize.height
        )
        guard (0...1).contains(position.x), (0...1).contains(position.y) else { return nil }

        return LiveViewFocusPoint(
            position: position,
            frameSize: CGSize(
                width: min(focusFrameSize.width / displayAreaSize.width, 1),
                height: min(focusFrameSize.height / displayAreaSize.height, 1)
            )
        )
    }

    func cameraPoint(forDisplayedPoint point: CGPoint) -> CGPoint {
        let normalized = CGPoint(
            x: min(max(point.x, 0), 1),
            y: min(max(point.y, 0), 1)
        )
        let displayOrigin = CGPoint(
            x: displayCenter.x - displayAreaSize.width / 2,
            y: displayCenter.y - displayAreaSize.height / 2
        )
        let requested = CGPoint(
            x: displayOrigin.x + normalized.x * displayAreaSize.width,
            y: displayOrigin.y + normalized.y * displayAreaSize.height
        )
        let halfFrame = CGSize(
            width: focusFrameSize.width / 2,
            height: focusFrameSize.height / 2
        )
        return CGPoint(
            x: min(max(requested.x, halfFrame.width), wholeSize.width - halfFrame.width),
            y: min(max(requested.y, halfFrame.height), wholeSize.height - halfFrame.height)
        )
    }

    init?(
        liveViewData data: Data,
        hasVersion: Bool
    ) {
        if hasVersion {
            guard data.count >= 384 else { return nil }
            let wholeSize = CGSize(width: data.cgFloat16(at: 16), height: data.cgFloat16(at: 18))
            let displayAreaSize = CGSize(width: data.cgFloat16(at: 20), height: data.cgFloat16(at: 22))
            let displayCenter = CGPoint(x: data.cgFloat16(at: 24), y: data.cgFloat16(at: 26))
            let areaCount = min(Int(data[44]), 42)
            guard areaCount > 0 else { return nil }

            let selectedFaceIndex = Int(data[45])
            let areaIndex = selectedFaceIndex < areaCount ? selectedFaceIndex : 0
            let areaOffset = 48 + areaIndex * 8
            self.init(
                wholeSize: wholeSize,
                displayAreaSize: displayAreaSize,
                displayCenter: displayCenter,
                focusFrameSize: CGSize(
                    width: data.cgFloat16(at: areaOffset),
                    height: data.cgFloat16(at: areaOffset + 2)
                ),
                focusFrameCenter: CGPoint(
                    x: data.cgFloat16(at: areaOffset + 4),
                    y: data.cgFloat16(at: areaOffset + 6)
                ),
                isAFDrivingEnabled: data[40] == 1
            )
        } else {
            guard data.count >= 50 else { return nil }
            self.init(
                wholeSize: CGSize(width: data.cgFloat16(at: 12), height: data.cgFloat16(at: 14)),
                displayAreaSize: CGSize(width: data.cgFloat16(at: 16), height: data.cgFloat16(at: 18)),
                displayCenter: CGPoint(x: data.cgFloat16(at: 20), y: data.cgFloat16(at: 22)),
                focusFrameSize: CGSize(width: data.cgFloat16(at: 24), height: data.cgFloat16(at: 26)),
                focusFrameCenter: CGPoint(x: data.cgFloat16(at: 28), y: data.cgFloat16(at: 30)),
                isAFDrivingEnabled: data[49] == 1
            )
        }

        guard wholeSize.width > 0,
              wholeSize.height > 0,
              displayAreaSize.width > 0,
              displayAreaSize.height > 0
        else { return nil }
    }
}

@MainActor
final class CameraConnectionService: ObservableObject {
    static let autoConnectOnLaunchKey = "camera.autoConnectOnLaunch"
    static let usbFastConnectKey = "camera.usbFastConnect"

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
        var storages: [StorageInfo] = []
        var mediaObjectCount: Int?

        var storageName: String? {
            switch storages.count {
            case 0: return nil
            case 1: return storages[0].name
            default: return "\(storages.count) 张存储卡"
            }
        }

        var storageTotalBytes: UInt64? {
            aggregateStorageValue(\.totalBytes)
        }

        var storageFreeBytes: UInt64? {
            aggregateStorageValue(\.freeBytes)
        }

        private func aggregateStorageValue(_ keyPath: KeyPath<StorageInfo, UInt64>) -> UInt64? {
            guard !storages.isEmpty else { return nil }
            return storages.reduce(0) { partialResult, storage in
                let (sum, overflow) = partialResult.addingReportingOverflow(storage[keyPath: keyPath])
                return overflow ? UInt64.max : sum
            }
        }
    }

    struct StorageInfo: Identifiable, Equatable {
        let id: UInt32
        var name: String
        var totalBytes: UInt64
        var freeBytes: UInt64
        var freeImageCount: UInt32?
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
    /// 实时画面单独发布：每帧只刷新监看视图，不再触发整个标签页重建。
    let liveViewStream = LiveViewStream()
    /// 兼容原有调用点的转发属性（读写都落到 liveViewStream）。
    var liveViewImage: UIImage? {
        get { liveViewStream.image }
        set { liveViewStream.setImage(newValue) }
    }
    @Published private(set) var isLiveViewActive = false
    @Published private(set) var liveViewError: String?
    @Published private(set) var liveViewFrameRate: Double?
    @Published private(set) var liveViewRefreshInterval = LiveViewRefreshInterval.defaultValue
    @Published private(set) var liveViewFocusPoint: LiveViewFocusPoint?
    @Published private(set) var isLiveViewFocusPointAvailable = false
    @Published private(set) var isSettingLiveViewFocusPoint = false
    @Published private(set) var captureParameters: [CaptureParameter: UInt64] = [:]
    @Published private(set) var captureParameterOptions: [CaptureParameter: [CaptureOption]] = [:]
    @Published private(set) var isRefreshingCaptureParameters = false
    @Published private(set) var isRefreshingCaptureParameterCapabilities = false
    @Published private(set) var activeCaptureWrite: CaptureParameter?
    @Published private(set) var captureControlError: String?
    @Published private(set) var isInitiatingCapture = false
    @Published private(set) var isInitiatingAutoFocus = false

    var isCaptureControlBusy: Bool {
        activeCaptureWrite != nil || captureWriteTask != nil
    }

    /// 当前链路类型：Wi-Fi 或 USB 有线。
    @Published private(set) var linkKind: CameraLinkKind = .wifi
    /// USB 有线链路：设备发现、PTP 直通与内容目录。
    let usbLink = USBCameraLink()
    private var commandChannel: (any PTPChannel)?
    private var isUSBPTPReady = false
    private var usbCatalog: USBCameraCatalog = .empty
    private var usesUSBFastConnect = false
    private var isUsingUSBCatalogGallery = false
    private var usbLinkObserver: AnyCancellable?
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
    private var metadataRecordsByHandle: [UInt32: NikonObjectMetadata] = [:]
    private var metadataResolvedItems: [UInt32: GalleryItem] = [:]
    private var metadataExcludedHandles: Set<UInt32> = []
    private var metadataAttemptedHandles: Set<UInt32> = []
    private var metadataInfoTasks: [UInt32: Task<ParsedObjectInfo?, Never>] = [:]
    private var metadataConnection: (any PTPChannel)?
    private var metadataDirectoryID: UInt32?
    private var metadataRecords: [NikonObjectMetadata] = []
    private var metadataRevision = 0
    private var galleryEventRevisions: [UInt32: UInt64] = [:]
    private var liveViewTask: Task<Void, Never>?
    private var liveViewGeneration = 0
    private var liveViewConsumers = 0
    private var liveViewFrameCount = 0
    private var liveViewFrameWindowStart = Date()
    private var liveViewFocusMetadata: NikonLiveViewFocusMetadata?
    private var lastEndpoint: NWEndpoint?
    private var lastDisplayHost: String?
    private var reconnectTask: Task<Void, Never>?
    private var connectionGeneration = UUID()
    private var pendingCaptureWrites: [CaptureParameter: UInt64] = [:]
    private var captureWriteTask: Task<Void, Never>?
    private var pendingCapturePropertyRefreshes: [CaptureParameter: UInt16] = [:]
    private var capturePropertyRefreshTask: Task<Void, Never>?
    private var capturePropertyDescriptions: [CaptureParameter: CapturePropertyDescription] = [:]
    private var foregroundObserver: NSObjectProtocol?

    private static let lastConnectedHostKey = "camera.lastConnectedHost"
    private static let liveViewRefreshIntervalKey = "capture.liveViewRefreshInterval"

    init() {
        if let rawValue = UserDefaults.standard.string(forKey: Self.liveViewRefreshIntervalKey),
           let interval = LiveViewRefreshInterval(rawValue: rawValue)
        {
            liveViewRefreshInterval = interval
        }

        if let rememberedHost = UserDefaults.standard.string(forKey: Self.lastConnectedHostKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !rememberedHost.isEmpty
        {
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
        observeUSBCameraLink()
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
        linkKind = .wifi
        let generation = UUID()
        connectionGeneration = generation

        do {
            let channel = PTPIPTCPChannel(endpoint: endpoint)
            channel.logHandler = { [weak self] message in
                self?.appendLog(message)
            }
            channel.failureHandler = { [weak self] reason in
                self?.noteTransportFailure(reason: reason)
            }
            channel.eventHandler = { [weak self, weak channel] event in
                guard let self, let channel else { return }
                Task { @MainActor [weak self, weak channel] in
                    guard let self, let channel, self.connectionGeneration == generation else { return }
                    self.handlePTPEvent(event, on: channel, connectionGeneration: generation)
                }
            }
            commandChannel = channel
            try await channel.open()
            appendLog("[command] PTP/IP 会话已建立 connectionNumber=\(channel.connectionNumber ?? 0)")

            try await establishSession(on: channel)

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

    /// 建立 PTP 会话并读取机身信息。Wi-Fi 与 USB 共用同一套流程。
    private func establishSession(on connection: any PTPChannel) async throws {
        transactionID = 0
        let sessionID: UInt32 = 1
        let openSessionResponse = try await operation(
            .openSession,
            parameters: [sessionID],
            dataPhase: nil,
            on: connection
        )
        if openSessionResponse.code != PTPResponseCode.ok.rawValue,
           openSessionResponse.code != PTPResponseCode.sessionAlreadyOpen.rawValue
        {
            throw CameraConnectionError.ptpResponse(openSessionResponse.code)
        }
        if openSessionResponse.code == PTPResponseCode.sessionAlreadyOpen.rawValue {
            appendLog("OpenSession 返回会话已存在（0x201E），沿用相机会话")
        }

        let deviceInfoResponse = try await operation(
            .getDeviceInfo,
            parameters: [],
            dataPhase: .receive,
            on: connection
        )
        guard deviceInfoResponse.code == PTPResponseCode.ok.rawValue,
              let deviceInfo = deviceInfoResponse.data
        else {
            throw CameraConnectionError.ptpResponse(deviceInfoResponse.code)
        }

        cameraInfo = try parseDeviceInfo(deviceInfo)
        appendLog(
            "DeviceInfo 解析成功 manufacturer=\(cameraInfo?.manufacturer ?? ""), " +
                "model=\(cameraInfo?.model ?? ""), serial=\(cameraInfo?.serialNumber ?? "")"
        )
        cameraStatus = await readCameraStatus(on: connection)
        lensInfo = await readLensInfo(on: connection)
    }

    /// USB 有线连接：先打开 ImageCaptureCore 会话，再按相机能力启用 PTP 直通。
    func connectUSBCamera(_ descriptor: USBCameraDescriptor, fastConnect: Bool = true) async {
        if case .connecting = state, linkKind == .usb {
            appendLog("[usb] 忽略重复连接请求 device=\(descriptor.title)")
            return
        }
        reconnectTask?.cancel()
        reconnectTask = nil
        lastEndpoint = nil
        lastDisplayHost = nil
        disconnect(clearRememberedDevice: false)
        let generation = UUID()
        connectionGeneration = generation
        state = .connecting
        linkKind = .usb
        isUSBPTPReady = false
        usbCatalog = .empty
        usesUSBFastConnect = fastConnect
        isUsingUSBCatalogGallery = false
        observeUSBCameraLink()

        do {
            try await usbLink.open(descriptor, loadContentCatalog: !fastConnect)
            guard connectionGeneration == generation else { return }
            usbCatalog = usbLink.catalogSnapshot()
            connectedHost = "\(descriptor.title)（USB）"

            if usbLink.isPTPReady {
                let channel = USBPTPChannel(link: usbLink)
                commandChannel = channel
                do {
                    try await establishSession(on: channel)
                    guard connectionGeneration == generation else { return }
                    isUSBPTPReady = true
                    appendLog("[usb] PTP 直通会话已建立")
                } catch {
                    appendLog("[usb] PTP 会话初始化失败，降级为目录模式 error=\(error.localizedDescription)")
                    channel.close()
                    commandChannel = nil
                }
            } else {
                appendLog("[usb] 相机未开放 PTP 直通，仅使用 USB 目录读取")
            }

            if !isUSBPTPReady {
                applyUSBOnlyCameraInfo(descriptor)
            }

            state = .connected
            isReconnecting = false
            appendLog("USB 连接成功")
        } catch {
            guard connectionGeneration == generation else { return }
            appendLog("USB 连接失败 error=\(error.localizedDescription)")
            usbLink.closeSession()
            disconnectConnections()
            state = .failed(error.localizedDescription)
        }
    }

    /// 无 PTP 直通时，用系统提供的设备信息填充界面。
    private func applyUSBOnlyCameraInfo(_ descriptor: USBCameraDescriptor) {
        cameraInfo = CameraInfo(
            manufacturer: descriptor.manufacturerName,
            model: descriptor.title,
            serialNumber: descriptor.serialNumber
        )
        var status = CameraStatus()
        status.batteryLevel = usbLink.batteryLevel
        cameraStatus = status
    }

    private func observeUSBCameraLink() {
        guard usbLinkObserver == nil else { return }
        usbLink.logHandler = { [weak self] message in
            self?.appendLog(message)
        }
        usbLink.deviceDisconnectedHandler = { [weak self] reason in
            self?.handleUSBDisconnect(reason: reason)
        }
        usbLink.eventHandler = { [weak self] event in
            guard let self, let channel = self.commandChannel else { return }
            self.handlePTPEvent(
                event,
                on: channel,
                connectionGeneration: self.connectionGeneration
            )
        }
        usbLinkObserver = usbLink.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    private func handleUSBDisconnect(reason: String) {
        guard linkKind == .usb else { return }
        switch state {
        case .connecting, .connected:
            break
        case .disconnected, .failed:
            return
        }
        connectionGeneration = UUID()
        appendLog("检测到 USB 连接断开 reason=\(reason)")
        disconnect(clearRememberedDevice: false)
        state = .failed("USB 连接已断开，请重新插拔数据线后重试")
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
        captureParameterOptions = [:]
        capturePropertyDescriptions = [:]
        pendingCaptureWrites = [:]
        captureWriteTask?.cancel()
        captureWriteTask = nil
        pendingCapturePropertyRefreshes = [:]
        capturePropertyRefreshTask?.cancel()
        capturePropertyRefreshTask = nil
        activeCaptureWrite = nil
        isRefreshingCaptureParameters = false
        isRefreshingCaptureParameterCapabilities = false
        isInitiatingCapture = false
        isInitiatingAutoFocus = false
        captureControlError = nil
        stopLiveViewInternal(sendEndCommand: false)
        isUSBPTPReady = false
        usbCatalog = .empty
        usesUSBFastConnect = false
        isUsingUSBCatalogGallery = false
        linkKind = .wifi
        usbLink.closeSession()
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
            // USB 链路由 ImageCaptureCore 回调通知断线，不做 TCP 探测。
            if linkKind == .wifi, let channel = commandChannel, !channel.isReady {
                beginAutomaticReconnect(reason: "应用回到前台后检测到连接已断开")
            }
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

    private func noteTransportFailure(reason: String) {
        guard case .connected = state, linkKind == .wifi else { return }
        appendLog("检测到相机连接断开 reason=\(reason)")
        beginAutomaticReconnect(reason: reason)
    }

    private func beginAutomaticReconnect(reason: String) {
        if reconnectTask != nil { return }
        // USB 断线由 ImageCaptureCore 回调处理，这里只负责 PTP/IP 自动重连。
        guard linkKind == .wifi else { return }
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
        guard case .connected = state else { return }
        if linkKind == .usb {
            await refreshUSBCameraStatus()
            return
        }
        guard let channel = commandChannel else { return }
        appendLog("开始刷新相机状态")
        cameraStatus = await readCameraStatus(on: channel)
        lensInfo = await readLensInfo(on: channel)
    }

    /// USB 状态下电量来自系统，容量等指标仍走 PTP 直通（如果相机支持）。
    private func refreshUSBCameraStatus() async {
        var status = CameraStatus()
        status.batteryLevel = usbLink.batteryLevel
        if isUSBPTPReady, let channel = commandChannel {
            let ptpStatus = await readCameraStatus(on: channel)
            if ptpStatus.batteryLevel != nil {
                status.batteryLevel = ptpStatus.batteryLevel
            }
            status.storages = ptpStatus.storages
            status.mediaObjectCount = ptpStatus.mediaObjectCount
            lensInfo = await readLensInfo(on: channel)
        }
        if status.mediaObjectCount == nil, usbCatalog.objectCount > 0 {
            status.mediaObjectCount = usbCatalog.objectCount
        }
        cameraStatus = status
    }

    func refreshCameraStatusPeriodically(every interval: Duration = .seconds(3)) async {
        guard case .connected = state else { return }

        while !Task.isCancelled {
            try? await Task.sleep(for: interval)
            if Task.isCancelled { break }
            await refreshCameraStatus()
        }
    }

    private func beginGalleryLoad() -> Int {
        invalidateGalleryLoad()
        return galleryLoadGeneration
    }

    private func invalidateGalleryLoad() {
        galleryLoadGeneration &+= 1
        galleryEnrichmentTask?.cancel()
        galleryEnrichmentTask = nil
        for task in metadataInfoTasks.values { task.cancel() }
        metadataInfoTasks = [:]
        metadataRecordsByHandle = [:]
        metadataResolvedItems = [:]
        metadataExcludedHandles = []
        metadataAttemptedHandles = []
        metadataConnection = nil
        metadataDirectoryID = nil
        metadataRecords = []
        metadataRevision = 0
        galleryEventRevisions = [:]
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

    private func handlePTPEvent(
        _ event: PTPEvent,
        on connection: any PTPChannel,
        connectionGeneration: UUID
    ) {
        switch PTPEventCode(rawValue: event.code) {
        case .objectAdded:
            guard let handle = event.parameters.first else {
                appendLog("[event] \(event.debugName) 缺少 ObjectHandle")
                return
            }
            let revision = nextGalleryEventRevision(for: handle)
            Task { [weak self] in
                await self?.applyObjectAdded(
                    handle: handle,
                    revision: revision,
                    on: connection,
                    connectionGeneration: connectionGeneration
                )
            }
        case .objectRemoved:
            guard let handle = event.parameters.first else {
                appendLog("[event] \(event.debugName) 缺少 ObjectHandle")
                return
            }
            _ = nextGalleryEventRevision(for: handle)
            applyObjectRemoved(handle: handle)
        case .devicePropChanged:
            guard let rawPropertyCode = event.parameters.first,
                  let propertyCode = UInt16(exactly: rawPropertyCode)
            else {
                appendLog("[event] \(event.debugName) 缺少有效的 DevicePropCode")
                return
            }
            guard let parameter = CaptureParameter.matching(propertyCode: propertyCode) else {
                return
            }
            queueCapturePropertyRefresh(
                parameter,
                propertyCode: propertyCode,
                on: connection,
                connectionGeneration: connectionGeneration
            )
        case nil:
            break
        }
    }

    private func nextGalleryEventRevision(for handle: UInt32) -> UInt64 {
        let revision = (galleryEventRevisions[handle] ?? 0) &+ 1
        galleryEventRevisions[handle] = revision
        return revision
    }

    private func queueCapturePropertyRefresh(
        _ parameter: CaptureParameter,
        propertyCode: UInt16,
        on connection: any PTPChannel,
        connectionGeneration: UUID
    ) {
        pendingCapturePropertyRefreshes[parameter] = propertyCode
        guard capturePropertyRefreshTask == nil else { return }

        capturePropertyRefreshTask = Task { [weak self] in
            await self?.drainCapturePropertyRefreshes(
                on: connection,
                connectionGeneration: connectionGeneration
            )
        }
    }

    private func drainCapturePropertyRefreshes(
        on connection: any PTPChannel,
        connectionGeneration: UUID
    ) async {
        defer {
            if self.connectionGeneration == connectionGeneration {
                capturePropertyRefreshTask = nil
            }
        }

        while !Task.isCancelled, let next = pendingCapturePropertyRefreshes.first {
            guard self.connectionGeneration == connectionGeneration,
                  case .connected = state,
                  commandChannel === connection
            else {
                if self.connectionGeneration == connectionGeneration {
                    pendingCapturePropertyRefreshes = [:]
                }
                return
            }

            pendingCapturePropertyRefreshes.removeValue(forKey: next.key)
            if activeCaptureWrite == next.key {
                continue
            }

            guard let rawValue = await readDeviceProperty(next.value, on: connection) else {
                appendLog(
                    "[capture][event] 属性回读失败 name=\(next.key.title) code=0x" +
                        String(format: "%04X", next.value)
                )
                continue
            }
            guard self.connectionGeneration == connectionGeneration else { return }

            let value = next.key.normalizeRead(rawValue, from: next.value)
            captureParameters[next.key] = value
            appendLog(
                "[capture][event] 属性已更新 name=\(next.key.title) code=0x" +
                    String(format: "%04X", next.value) + " raw=\(value)"
            )
        }
    }

    private func applyObjectAdded(
        handle: UInt32,
        revision: UInt64,
        on connection: any PTPChannel,
        connectionGeneration: UUID
    ) async {
        guard galleryItems.allSatisfy({
            $0.handle != handle && $0.rawHandle != handle && $0.jpegHandle != handle
        }) else {
            appendLog("[图库][event] ObjectAdded 已存在 handle=0x\(String(format: "%08X", handle))")
            return
        }

        var info: ParsedObjectInfo?
        for attempt in 1...5 {
            guard self.connectionGeneration == connectionGeneration,
                  galleryEventRevisions[handle] == revision,
                  !Task.isCancelled else { return }
            do {
                info = try await fetchObjectInfo(handle: handle, on: connection, priority: .foreground)
            } catch {
                appendLog(
                    "[图库][event] ObjectAdded 读取信息失败 handle=0x\(String(format: "%08X", handle)) " +
                        "attempt=\(attempt) error=\(error.localizedDescription)"
                )
            }
            if info != nil { break }
            if attempt < 5 {
                try? await Task.sleep(for: .milliseconds(200))
            }
        }

        guard self.connectionGeneration == connectionGeneration,
              galleryEventRevisions[handle] == revision,
              let info else {
            appendLog("[图库][event] ObjectAdded 无法取得对象信息 handle=0x\(String(format: "%08X", handle))")
            return
        }
        guard !isAssociationObject(objectFormat: info.objectFormat),
              isGalleryMedia(objectFormat: info.objectFormat, filename: info.filename) else {
            appendLog("[图库][event] ObjectAdded 跳过非媒体 handle=0x\(String(format: "%08X", handle))")
            return
        }
        guard let directory = galleryDirectories.first(where: { $0.id == selectedGalleryDirectoryID }),
              await object(info, belongsTo: directory, on: connection) else {
            appendLog(
                "[图库][event] ObjectAdded 不属于当前目录 handle=0x\(String(format: "%08X", handle)) " +
                    "parent=0x\(String(format: "%08X", info.parentObject))"
            )
            return
        }
        guard self.connectionGeneration == connectionGeneration,
              galleryEventRevisions[handle] == revision else { return }

        let item = makeGalleryItem(handle: handle, info: info)
        galleryItems = Self.galleryItemsByAdding(item, to: galleryItems)
        if metadataDirectoryID == directory.id {
            let record = NikonObjectMetadata(
                handle: handle,
                attribute: 0,
                unknown: 0,
                captureDate: item.captureDate
            )
            metadataRecords.removeAll { $0.handle == handle }
            metadataRecords.append(record)
            metadataRecordsByHandle[handle] = record
            metadataResolvedItems[handle] = item
            metadataExcludedHandles.remove(handle)
            metadataAttemptedHandles.insert(handle)
            metadataRevision &+= 1
        }
        if let count = cameraStatus.mediaObjectCount {
            cameraStatus.mediaObjectCount = count + 1
        }
        appendLog(
            "[图库][event] 已增加 \(info.filename) handle=0x\(String(format: "%08X", handle)) " +
                "captureDate=\(item.captureDate.map(String.init(describing:)) ?? "nil")"
        )
    }

    private func object(
        _ info: ParsedObjectInfo,
        belongsTo directory: GalleryDirectory,
        on connection: any PTPChannel
    ) async -> Bool {
        guard info.storageID == directory.storageID else { return false }
        if directory.isSyntheticRoot { return true }

        var parent = info.parentObject
        var visited = Set<UInt32>()
        for _ in 0..<32 {
            if parent == directory.handle { return true }
            if parent == 0 || parent == 0xffff_ffff || !visited.insert(parent).inserted {
                return false
            }
            guard let parentInfo = try? await fetchObjectInfo(
                handle: parent,
                on: connection,
                priority: .foreground
            ) else { return false }
            parent = parentInfo.parentObject
        }
        return false
    }

    private func applyObjectRemoved(handle: UInt32) {
        let containedHandle = galleryItems.contains {
            $0.handle == handle || $0.rawHandle == handle || $0.jpegHandle == handle
        }
        galleryItems = Self.galleryItemsByRemoving(handle: handle, from: galleryItems)
        thumbnailCache[handle] = nil
        previewImageCache[handle] = nil
        objectImageCache[handle] = nil
        metadataInfoTasks[handle]?.cancel()
        metadataInfoTasks[handle] = nil
        metadataRecordsByHandle[handle] = nil
        metadataResolvedItems[handle] = nil
        metadataExcludedHandles.remove(handle)
        metadataAttemptedHandles.remove(handle)
        metadataRecords.removeAll { $0.handle == handle }
        metadataRevision &+= 1
        if containedHandle, let count = cameraStatus.mediaObjectCount {
            cameraStatus.mediaObjectCount = max(count - 1, 0)
        }
        appendLog("[图库][event] 已移除 handle=0x\(String(format: "%08X", handle))")
    }

    private func waitForRecoveredCommandConnection(
        generation: Int,
        directoryID: UInt32
    ) async -> (any PTPChannel)? {
        for _ in 0..<60 {
            guard isMatchingGalleryLoad(generation, directoryID: directoryID) else { return nil }
            if case .connected = state,
               let connection = commandChannel,
               connection.isReady
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
        guard case .connected = state else {
            galleryItems = []
            galleryDirectories = []
            selectedGalleryDirectoryID = nil
            appendLog("[图库] 未连接相机，跳过刷新")
            return
        }

        if linkKind == .usb {
            if usesUSBFastConnect {
                let didLoadViaPTP = await refreshGalleryViaPTP(
                    selectingDirectoryID: directoryID,
                    generation: generation
                )
                guard !didLoadViaPTP, isCurrentGalleryLoad(generation) else { return }
                appendLog("[图库] PTP 图库刷新失败，开始 USB 内容目录兜底")
                do {
                    usbCatalog = try await usbLink.loadCatalogSnapshot()
                    guard isCurrentGalleryLoad(generation) else { return }
                    await refreshUSBGallery(
                        selectingDirectoryID: directoryID,
                        generation: generation,
                        fallsBackToPTP: false
                    )
                } catch {
                    guard isCurrentGalleryLoad(generation) else { return }
                    appendLog("[图库] USB 内容目录兜底失败 error=\(error.localizedDescription)")
                }
                return
            }
            await refreshUSBGallery(selectingDirectoryID: directoryID, generation: generation)
            return
        }

        guard let channel = commandChannel else {
            galleryItems = []
            galleryDirectories = []
            selectedGalleryDirectoryID = nil
            appendLog("[图库] 未连接相机，跳过刷新")
            return
        }

        appendLog("[图库] 开始刷新目录列表")
        do {
            let directories = try await loadGalleryDirectories(on: channel)
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

            _ = await loadGalleryMedia(forDirectoryID: selected, clearCaches: true, generation: generation)
        } catch {
            guard isCurrentGalleryLoad(generation) else { return }
            appendLog("[图库] 目录列表失败 error=\(error.localizedDescription)")
        }
    }

    /// USB 图库：目录与对象列表直接来自系统内容目录，省掉逐条 PTP 轮询。
    private func refreshUSBGallery(
        selectingDirectoryID directoryID: UInt32?,
        generation: Int,
        fallsBackToPTP: Bool = true
    ) async {
        let startedAt = Date()
        appendLog("[图库] USB 目录刷新开始")
        usbCatalog = usbLink.refreshCatalogSnapshot()
        guard isCurrentGalleryLoad(generation) else { return }

        let directories = usbCatalog.folders.map(Self.makeGalleryDirectory)
        guard !directories.isEmpty else {
            if fallsBackToPTP {
                appendLog("[图库] USB 内容目录为空，回退 PTP 枚举")
                _ = await refreshGalleryViaPTP(selectingDirectoryID: directoryID, generation: generation)
            } else {
                galleryDirectories = []
                galleryItems = []
                selectedGalleryDirectoryID = nil
                appendLog("[图库] USB 内容目录兜底为空")
            }
            return
        }

        isUsingUSBCatalogGallery = true
        galleryDirectories = directories
        let preferred = directoryID ?? selectedGalleryDirectoryID
        let selected = directories.first(where: { $0.id == preferred })?.id ?? directories.first?.id
        selectedGalleryDirectoryID = selected
        appendLog("[图库] USB 目录列表完成 dirs=\(directories.count)")

        guard let selected else {
            galleryItems = []
            appendLog("[图库] 没有可选择的目录")
            return
        }
        await loadUSBGalleryMedia(forDirectoryID: selected, generation: generation)
        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        appendLog("[图库] USB 刷新完成 elapsedMs=\(elapsedMs)")
    }

    /// USB 目录不可用时沿用 PTP 枚举（需要 PTP 直通）。
    @discardableResult
    private func refreshGalleryViaPTP(
        selectingDirectoryID directoryID: UInt32?,
        generation: Int
    ) async -> Bool {
        guard isUSBPTPReady, let channel = commandChannel else {
            galleryDirectories = []
            galleryItems = []
            appendLog("[图库] PTP 回退不可用")
            return false
        }
        do {
            let directories = try await loadGalleryDirectories(on: channel)
            guard isCurrentGalleryLoad(generation) else { return false }
            isUsingUSBCatalogGallery = false
            galleryDirectories = directories
            let preferred = directoryID ?? selectedGalleryDirectoryID
            let selected = directories.first(where: { $0.id == preferred })?.id ?? directories.first?.id
            selectedGalleryDirectoryID = selected
            guard let selected else {
                galleryItems = []
                return true
            }
            return await loadGalleryMedia(
                forDirectoryID: selected,
                clearCaches: true,
                generation: generation
            )
        } catch {
            guard isCurrentGalleryLoad(generation) else { return false }
            appendLog("[图库] PTP 回退失败 error=\(error.localizedDescription)")
            return false
        }
    }

    private func loadUSBGalleryMedia(forDirectoryID directoryID: UInt32, generation: Int) async {
        guard let folder = usbCatalog.folders.first(where: { $0.handle == directoryID }) else {
            appendLog("[图库] USB 目录不存在 handle=0x\(String(format: "%08X", directoryID))")
            galleryItems = []
            return
        }

        let startedAt = Date()
        let items = buildUSBGalleryItems(folder.entries)
        guard isCurrentGalleryLoad(generation, directoryID: directoryID) else { return }

        thumbnailCache = [:]
        previewImageCache = [:]
        objectImageCache = [:]
        galleryItems = items

        let photos = items.filter { !$0.isVideo }.count
        let videos = items.filter(\.isVideo).count
        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        appendLog(
            "[图库] USB 目录媒体完成 dir=\(folder.path) photos=\(photos) videos=\(videos) " +
                "total=\(items.count) elapsedMs=\(elapsedMs)"
        )
    }

    private nonisolated static func makeGalleryDirectory(_ folder: USBCameraCatalog.Folder) -> GalleryDirectory {
        GalleryDirectory(
            id: folder.handle,
            storageID: folder.storageID,
            name: folder.name,
            path: folder.path,
            isSyntheticRoot: folder.isSyntheticRoot
        )
    }

    /// 把 USB 目录条目映射成图库条目，RAW/JPEG 配对复用与 PTP 分支相同的合并规则。
    private func buildUSBGalleryItems(_ entries: [USBCameraCatalog.Entry]) -> [GalleryItem] {
        var candidates: [GalleryItem] = []
        for entry in entries {
            let isVideo = entry.isVideo || isVideoMedia(objectFormat: 0, filename: entry.filename)
            let isRAW = !isVideo && (entry.isRAW || isRAWMedia(objectFormat: 0, filename: entry.filename))
            guard isVideo || isRAW || isImageMedia(objectFormat: 0, filename: entry.filename) else { continue }
            candidates.append(
                GalleryItem(
                    id: entry.handle,
                    filename: entry.filename,
                    objectFormat: isVideo ? 0x300d : (isRAW ? 0xb802 : 0x3801),
                    fileSize: entry.fileSize,
                    isVideo: isVideo,
                    captureDate: entry.captureDate,
                    rawHandle: isRAW ? entry.handle : nil,
                    rawFilename: isRAW ? entry.filename : nil,
                    rawFileSize: isRAW ? entry.fileSize : nil,
                    jpegHandle: (!isVideo && !isRAW) ? entry.handle : nil,
                    jpegFilename: (!isVideo && !isRAW) ? entry.filename : nil,
                    jpegFileSize: (!isVideo && !isRAW) ? entry.fileSize : nil
                )
            )
        }
        return Self.sortedGalleryItems(Self.mergePairedPhotos(candidates))
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
        if linkKind == .usb, isUsingUSBCatalogGallery {
            await loadUSBGalleryMedia(forDirectoryID: id, generation: generation)
            return
        }
        _ = await loadGalleryMedia(forDirectoryID: id, clearCaches: true, generation: generation)
    }

    private func loadGalleryMedia(
        forDirectoryID directoryID: UInt32,
        clearCaches: Bool,
        generation: Int
    ) async -> Bool {
        guard case .connected = state, let channel = commandChannel else {
            appendLog("[图库] 未连接相机，跳过媒体加载")
            return false
        }
        guard let directory = galleryDirectories.first(where: { $0.id == directoryID }) else {
            appendLog("[图库] 媒体加载失败：目录无效")
            return false
        }

        if clearCaches {
            thumbnailCache = [:]
            previewImageCache = [:]
            objectImageCache = [:]
        }

        let startedAt = Date()
        appendLog("[图库] 开始加载目录 \(directory.pickerTitle) path=\(directory.path) handle=0x\(String(format: "%08X", directory.handle))")
        var mediaConnection = channel
        if supportedOperations.contains(PTPOperationCode.getObjectsMetadata.rawValue) {
            appendLog("[图库] GetObjectsMetaData可用")
            appendLog("[图库] 使用 GetObjectsMetaData 获取列表")
            do {
                let metadata = try await fetchNikonObjectsMetadata(in: directory, on: channel)
                guard isCurrentGalleryLoad(generation, directoryID: directoryID) else { return false }
                let records = metadata.records
                let skeleton = await Task.detached(priority: .userInitiated) {
                    records.map(Self.makeSkeletonItem)
                }.value
                guard isCurrentGalleryLoad(generation, directoryID: directoryID) else { return false }
                galleryItems = skeleton
                appendLog("[图库] GetObjectsMetaData成功生成对象数=\(skeleton.count)")
                metadataRecords = records
                metadataRecordsByHandle = Dictionary(records.map { ($0.handle, $0) }, uniquingKeysWith: { first, _ in first })
                metadataConnection = channel
                metadataDirectoryID = directoryID
                galleryEnrichmentTask = Task { [weak self] in
                    await self?.enrichMetadataGallery(
                        metadata,
                        in: directory,
                        on: channel,
                        generation: generation
                    )
                }
                return true
            } catch {
                guard isMatchingGalleryLoad(generation, directoryID: directoryID) else { return false }
                appendLog("[图库] GetObjectsMetaData失败 reason=\(error.localizedDescription)")
                appendLog("[图库] GetObjectsMetaData失败，回退标准对象枚举")
                if channel.isReady {
                    mediaConnection = channel
                } else if let recovered = await waitForRecoveredCommandConnection(
                    generation: generation,
                    directoryID: directoryID
                ) {
                    mediaConnection = recovered
                    appendLog("[图库] 连接恢复完成，开始标准对象枚举")
                } else {
                    appendLog("[图库] 标准对象枚举未启动 reason=连接恢复超时")
                    return false
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
            guard isCurrentGalleryLoad(generation, directoryID: directoryID) else { return false }
            galleryItems = items
            let photos = items.filter { !$0.isVideo }.count
            let videos = items.filter(\.isVideo).count
            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            appendLog(
                "[图库] 目录媒体完成 dir=\(directory.pickerTitle) photos=\(photos) videos=\(videos) " +
                "total=\(items.count) elapsedMs=\(elapsedMs)"
            )
            return true
        } catch {
            guard isCurrentGalleryLoad(generation, directoryID: directoryID) else { return false }
            appendLog("[图库] 目录媒体失败 dir=\(directory.pickerTitle) error=\(error.localizedDescription)")
            return false
        }
    }

    func thumbnailImage(for handle: UInt32) async -> UIImage? {
        if let cached = thumbnailCache[handle], let image = UIImage(data: cached) {
            return image
        }

        if linkKind == .usb, usbLink.hasObject(handle: handle) {
            do {
                if let data = try await usbLink.thumbnailData(forHandle: handle) {
                    thumbnailCache[handle] = data
                    return UIImage(data: data)
                }
                appendLog("[图库] USB 缩略图为空 handle=0x\(String(format: "%08X", handle))")
            } catch {
                appendLog(
                    "[图库] USB 缩略图失败 handle=0x\(String(format: "%08X", handle)) " +
                        "error=\(error.localizedDescription)"
                )
            }
        }

        guard case .connected = state, let channel = commandChannel else {
            appendLog("[图库] 缩略图跳过 handle=0x\(String(format: "%08X", handle)) reason=未连接")
            return nil
        }

        let filename = galleryItems.first(where: { $0.handle == handle })?.filename
        do {
            let response = try await operation(
                .getThumb,
                parameters: [handle],
                dataPhase: .receive,
                on: channel,
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
        guard case .connected = state else { return nil }

        if linkKind == .usb, usbLink.hasObject(handle: handle) {
            do {
                let data = try await usbLink.readObjectData(forHandle: handle)
                guard !data.isEmpty else { return nil }
                objectImageCache[handle] = data
                return data
            } catch {
                appendLog(
                    "[图库] USB 原始文件下载失败 handle=0x\(String(format: "%08X", handle)) " +
                        "error=\(error.localizedDescription)"
                )
                return nil
            }
        }

        guard let channel = commandChannel else { return nil }
        do {
            let response = try await operation(.getObject, parameters: [handle], dataPhase: .receive, on: channel, logStyle: .silent)
            guard response.code == PTPResponseCode.ok.rawValue, let data = response.data, !data.isEmpty else { return nil }
            objectImageCache[handle] = data
            return data
        } catch {
            appendLog("[图库] 原始文件下载失败 handle=0x\(String(format: "%08X", handle)) error=\(error.localizedDescription)")
            return nil
        }
    }

    /// Reads an object in chunks and reports the number of bytes received after each chunk.
    func objectData(for handle: UInt32, progress: @escaping @MainActor (UInt64, UInt64) -> Void) async throws -> Data {
        guard case .connected = state else {
            throw CameraConnectionError.connectionCancelled
        }

        let total = galleryItems.first(where: { $0.handle == handle })?.fileSize ?? 0

        // USB 优先走系统的大块读取通道，吞吐远高于逐条 PTP 轮询。
        if linkKind == .usb, usbLink.hasObject(handle: handle) {
            return try await usbLink.readObjectData(forHandle: handle) { received, reportedTotal in
                progress(received, reportedTotal > 0 ? reportedTotal : total)
            }
        }

        guard let channel = commandChannel else {
            throw CameraConnectionError.connectionCancelled
        }
        return try await fetchPartialObject(handle: handle, on: channel) { received in
            progress(received, total)
        }
    }

    /// Deletes every object belonging to each selected photo. A RAW+JPEG item
    /// contributes both object handles, so the camera never retains its pair.
    func deleteGalleryItems(_ items: [GalleryItem]) async throws {
        guard case .connected = state else {
            throw CameraConnectionError.connectionCancelled
        }
        guard let channel = commandChannel else {
            throw CameraConnectionError.usbUnavailable("当前 USB 连接未提供 PTP 直通，暂不支持删除相机内文件")
        }

        var handles = Set<UInt32>()
        for item in items where !item.isVideo {
            if let rawHandle = item.rawHandle {
                handles.insert(rawHandle)
            }
            if let jpegHandle = item.jpegHandle {
                handles.insert(jpegHandle)
            }
            if item.rawHandle == nil && item.jpegHandle == nil {
                handles.insert(item.handle)
            }
        }

        for handle in handles.sorted() {
            let response = try await operation(
                .deleteObject,
                parameters: [handle],
                dataPhase: nil,
                on: channel,
                logStyle: .compact,
                priority: .foreground
            )
            guard response.code == PTPResponseCode.ok.rawValue else {
                appendLog(
                    "[图库] 删除失败 handle=0x\(String(format: "%08X", handle)) " +
                        "code=0x\(String(format: "%04X", response.code))"
                )
                throw CameraConnectionError.ptpResponse(response.code)
            }
            appendLog("[图库] 删除成功 handle=0x\(String(format: "%08X", handle))")
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

            guard case .connected = state, let channel = commandChannel else { return nil }
            let filename = galleryItems.first(where: { $0.handle == handle })?.filename
            do {
                let response = try await operation(
                    .getPreviewImage,
                    parameters: [],
                    dataPhase: .receive,
                    on: channel,
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
        guard case .connected = state else { return nil }
        let filename = galleryItems.first(where: { $0.handle == handle })?.filename

        if linkKind == .usb, usbLink.hasObject(handle: handle) {
            do {
                let data = try await usbLink.readObjectData(forHandle: handle)
                guard !data.isEmpty, let image = UIImage(data: data) else {
                    appendLog(
                        "[图库] USB 原图无效 \(galleryItemLabel(handle: handle, filename: filename)) " +
                            "bytes=\(data.count)"
                    )
                    return nil
                }
                objectImageCache[handle] = data
                return image
            } catch {
                appendLog(
                    "[图库] USB 原图异常 \(galleryItemLabel(handle: handle, filename: filename)) " +
                        "error=\(error.localizedDescription)"
                )
                return nil
            }
        }

        guard let channel = commandChannel else { return nil }
        do {
            let data = try await fetchPartialObject(handle: handle, on: channel)
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

    private func fetchPartialObject(
        handle: UInt32,
        on connection: any PTPChannel,
        progress: (@MainActor (UInt64) -> Void)? = nil
    ) async throws -> Data {
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
            progress?(UInt64(collected.count))
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

    var captureExposureMode: CaptureExposureMode? {
        captureParameters[.exposureMode].flatMap { CaptureExposureMode(rawValue: $0) }
    }

    func canAdjustCaptureParameter(_ parameter: CaptureParameter) -> Bool {
        if CaptureParameter.capabilityCases.contains(parameter) {
            guard capturePropertyDescriptions[parameter]?.isWritable == true,
                  captureParameterOptions[parameter]?.isEmpty == false
            else { return false }
        }
        return parameter.isAdjustable(in: captureExposureMode)
    }

    func captureOptions(for parameter: CaptureParameter) -> [CaptureOption] {
        captureParameterOptions[parameter] ?? []
    }

    /// Query the camera's DevicePropDesc datasets when the Capture tab opens.
    /// The returned range or enum forms are the sole source for editable values.
    func refreshCaptureParameterCapabilities() async {
        guard case .connected = state, let channel = commandChannel else {
            captureParameterOptions = [:]
            capturePropertyDescriptions = [:]
            return
        }
        guard activeCaptureWrite == nil,
              captureWriteTask == nil,
              !isRefreshingCaptureParameterCapabilities
        else { return }

        isRefreshingCaptureParameterCapabilities = true
        captureControlError = nil
        defer { isRefreshingCaptureParameterCapabilities = false }

        var descriptions: [CaptureParameter: CapturePropertyDescription] = [:]
        var optionsByParameter: [CaptureParameter: [CaptureOption]] = [:]
        var currentValues = captureParameters

        for parameter in CaptureParameter.capabilityCases {
            if Task.isCancelled { break }
            guard let description = await readCapturePropertyDescription(
                for: parameter,
                on: channel
            ) else { continue }

            let normalizedValues = description.allowedValues.map {
                parameter.normalizeRead($0, from: description.propertyCode)
            }
            let options = CaptureOptionCatalog.options(
                for: parameter,
                rawValues: normalizedValues
            )
            let currentValue = parameter.normalizeRead(
                description.currentValue,
                from: description.propertyCode
            )

            descriptions[parameter] = description
            optionsByParameter[parameter] = options
            currentValues[parameter] = currentValue
            appendCapturePropertyDescriptionLog(
                parameter: parameter,
                description: description,
                optionCount: options.count
            )
        }

        capturePropertyDescriptions = descriptions
        captureParameterOptions = optionsByParameter
        captureParameters = currentValues

        if descriptions.isEmpty {
            captureControlError = "相机未返回可设置的拍摄参数。"
            appendLog("[capture] 可设置值读取失败：没有可用的属性描述")
        } else {
            appendLog(
                "[capture] 可设置值读取完成 names=" +
                    descriptions.keys.map(\.title).sorted().joined(separator: ",")
            )
        }
    }

    /// Read the exposure-related PTP properties shown in the Capture tab.
    func refreshCaptureParameters() async {
        guard case .connected = state, let channel = commandChannel else {
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
            if let value = await readCaptureParameter(parameter, on: channel) {
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

    /// Queue a capture parameter write. Values are coalesced while a PTP
    /// transaction is in flight, and the accepted value is read back after
    /// the write so the UI reflects the camera's actual state.
    func queueCaptureParameter(_ parameter: CaptureParameter, rawValue: UInt64) {
        guard case .connected = state else {
            captureControlError = "相机未连接。"
            return
        }
        guard canAdjustCaptureParameter(parameter) else {
            let mode = CaptureOptionCatalog.displayedValue(
                for: .exposureMode,
                rawValue: captureParameters[.exposureMode]
            )
            captureControlError = "\(parameter.title)在\(mode)模式下不可调整。"
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
    ///
    /// Nikon expects at least the no-AF marker in the operation parameters.
    /// Newer bodies also accept the record target (`0` means card); older
    /// variants expose only the single marker parameter.
    @discardableResult
    func initiateCaptureRecInMedia() async -> Bool {
        guard case .connected = state, let channel = commandChannel else {
            captureControlError = "相机未连接。"
            return false
        }
        guard !isInitiatingCapture else { return false }

        isInitiatingCapture = true
        captureControlError = nil
        defer { isInitiatingCapture = false }

        let parameterStrategies: [[UInt32]] = [
            [0xffffffff, 0],
            [0xffffffff]
        ]

        do {
            var lastResponseCode = PTPResponseCode.ok.rawValue
            for (index, parameters) in parameterStrategies.enumerated() {
                let response = try await operation(
                    .initiateCaptureRecInMedia,
                    parameters: parameters,
                    dataPhase: nil,
                    on: channel,
                    logStyle: .compact,
                    timeout: .seconds(8)
                )
                lastResponseCode = response.code

                if response.code == PTPResponseCode.ok.rawValue {
                    appendLog(
                        "[capture] InitiateCaptureRecInMedia 成功 " +
                            "parameters=\(logParameters(parameters))"
                    )
                    try await waitUntilDeviceReady(on: channel, logPrefix: "[capture]")
                    return true
                }

                appendLog(
                    "[capture] InitiateCaptureRecInMedia 拒绝 " +
                        "code=0x\(String(format: "%04X", response.code)) " +
                        "parameters=\(logParameters(parameters))"
                )

                let canRetryWithFewerParameters = index + 1 < parameterStrategies.count
                    && (response.code == PTPResponseCode.operationNotSupported.rawValue
                        || response.code == PTPResponseCode.invalidParameter.rawValue)
                guard canRetryWithFewerParameters else { break }
            }

            throw CameraConnectionError.ptpResponse(lastResponseCode)
        } catch {
            captureControlError = "拍摄失败：\(error.localizedDescription)"
            appendLog("[capture] InitiateCaptureRecInMedia 失败 error=\(error.localizedDescription)")
            return false
        }
    }

    /// Drive Nikon autofocus. AfDrive uses no parameters and no data phase.
    @discardableResult
    func initiateAutoFocus() async -> Bool {
        guard case .connected = state, let channel = commandChannel else {
            captureControlError = "相机未连接。"
            return false
        }
        guard !isInitiatingAutoFocus, !isInitiatingCapture else { return false }

        isInitiatingAutoFocus = true
        captureControlError = nil
        defer { isInitiatingAutoFocus = false }

        do {
            let response = try await operation(
                .autoFocusDrive,
                parameters: [],
                dataPhase: nil,
                on: channel,
                logStyle: .compact,
                priority: .foreground,
                timeout: .seconds(8)
            )
            guard response.code == PTPResponseCode.ok.rawValue else {
                throw CameraConnectionError.ptpResponse(response.code)
            }

            appendLog("[focus] AfDrive 成功")
            return await waitForAutoFocusCompletion(on: channel)
        } catch {
            captureControlError = "对焦失败：\(error.localizedDescription)"
            appendLog("[focus] AfDrive 失败 error=\(error.localizedDescription)")
            return false
        }
    }

    private func waitForAutoFocusCompletion(on connection: any PTPChannel) async -> Bool {
        guard supportsOperation(.deviceReady) else { return true }

        for attempt in 1...10 {
            do {
                let response = try await operation(
                    .deviceReady,
                    parameters: [],
                    dataPhase: nil,
                    on: connection,
                    logStyle: .silent,
                    priority: .foreground,
                    timeout: .seconds(5)
                )
                switch response.code {
                case PTPResponseCode.ok.rawValue:
                    appendLog("[focus] DeviceReady OK attempt=\(attempt)")
                    return true
                case PTPResponseCode.deviceBusy.rawValue:
                    try? await Task.sleep(for: .milliseconds(500))
                case PTPResponseCode.nikonOutOfFocus.rawValue:
                    captureControlError = "相机未能合焦。"
                    appendLog("[focus] DeviceReady 未合焦 attempt=\(attempt)")
                    return false
                default:
                    throw CameraConnectionError.ptpResponse(response.code)
                }
            } catch {
                captureControlError = "对焦失败：\(error.localizedDescription)"
                appendLog("[focus] 等待对焦完成失败 error=\(error.localizedDescription)")
                return false
            }
        }

        captureControlError = "等待相机对焦超时。"
        appendLog("[focus] 等待对焦完成超时")
        return false
    }

    private func logParameters(_ parameters: [UInt32]) -> String {
        parameters.map { String(format: "0x%08X", $0) }.joined(separator: ",")
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
        guard case .connected = state, let channel = commandChannel else {
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
                parameters: [UInt32(parameter.writePropertyCode(for: rawValue))],
                dataPhase: .send(parameter.writeData(for: rawValue)),
                on: channel,
                logStyle: .compact,
                timeout: .seconds(5)
            )

            var usedFallback = false
            if response.code != PTPResponseCode.ok.rawValue,
               !(parameter == .focusMode && rawValue == 5),
               let fallbackCode = parameter.fallbackPropertyCode,
               let fallbackData = parameter.fallbackData(for: rawValue)
            {
                appendLog(
                    "[capture] \(parameter.title) 属性 0x" +
                        String(format: "%04X", parameter.rawValue) +
                        " 失败 code=0x" + String(format: "%04X", response.code) +
                        "，尝试备用属性 0x\(String(format: "%04X", fallbackCode))"
                )
                response = try await operation(
                    .setDevicePropValue,
                    parameters: [UInt32(fallbackCode)],
                    dataPhase: .send(fallbackData),
                    on: channel,
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
            let actualValue = await readCaptureParameter(parameter, on: channel)
            if let actualValue {
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
        on connection: any PTPChannel
    ) async -> UInt64? {
        if let value = await readDeviceProperty(parameter.rawValue, on: connection) {
            return parameter.normalizeStandardRead(value)
        }
        if let fallbackCode = parameter.fallbackPropertyCode,
           let value = await readDeviceProperty(fallbackCode, on: connection)
        {
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

    func setLiveViewRefreshInterval(_ interval: LiveViewRefreshInterval) {
        guard liveViewRefreshInterval != interval else { return }
        liveViewRefreshInterval = interval
        UserDefaults.standard.set(interval.rawValue, forKey: Self.liveViewRefreshIntervalKey)
    }

    private func beginLiveViewSession() async {
        guard case .connected = state, let channel = commandChannel else {
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
        liveViewFrameRate = nil
        liveViewFocusPoint = nil
        isLiveViewFocusPointAvailable = false
        isSettingLiveViewFocusPoint = false
        liveViewFocusMetadata = nil
        liveViewFrameCount = 0
        liveViewFrameWindowStart = Date()
        appendLog("[liveview] 开始启动实时图传 generation=\(generation)")

        do {
            try await prepareLiveView(on: channel)
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
        liveViewFrameRate = nil
        liveViewFocusPoint = nil
        isLiveViewFocusPointAvailable = false
        isSettingLiveViewFocusPoint = false
        liveViewFocusMetadata = nil
        liveViewFrameCount = 0
        liveViewFrameWindowStart = Date()
        if !sendEndCommand {
            liveViewError = nil
            return
        }
        guard case .connected = state, let channel = commandChannel, supportsOperation(.endLiveView) else {
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
                    on: channel,
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

    private func prepareLiveView(on connection: any PTPChannel) async throws {
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
           supportsOperation(.changeApplicationMode)
        {
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

    private func waitUntilDeviceReady(on connection: any PTPChannel, logPrefix: String = "[liveview]") async throws {
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
                appendLog("\(logPrefix) DeviceReady OK attempt=\(attempt)")
                return
            }
            if response.code == PTPResponseCode.deviceBusy.rawValue {
                try await Task.sleep(for: .milliseconds(250))
                continue
            }
            appendLog("\(logPrefix) DeviceReady code=0x\(String(format: "%04X", response.code)) attempt=\(attempt)")
            try await Task.sleep(for: .milliseconds(250))
        }
        // Some bodies keep returning busy briefly; still allow frame polling to proceed.
        appendLog("\(logPrefix) DeviceReady 超时，继续尝试")
    }

    private func runLiveViewLoop(generation: Int) async {
        appendLog("[liveview] 拉流循环开始 generation=\(generation)")
        var consecutiveFailures = 0
        while !Task.isCancelled,
              generation == liveViewGeneration,
              liveViewConsumers > 0,
              case .connected = state,
              let channel = commandChannel
        {
            do {
                if let frame = try await fetchLiveViewFrame(
                    on: channel,
                    priority: .background
                ) {
                    applyLiveViewFrame(frame)
                    liveViewError = nil
                    consecutiveFailures = 0
                    liveViewFrameCount += 1
                    let now = Date()
                    let elapsed = now.timeIntervalSince(liveViewFrameWindowStart)
                    if elapsed >= 1 {
                        liveViewFrameRate = Double(liveViewFrameCount) / elapsed
                        liveViewFrameCount = 0
                        liveViewFrameWindowStart = now
                    }
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
            try? await Task.sleep(for: liveViewRefreshInterval.duration)
        }
        if generation == liveViewGeneration {
            isLiveViewActive = false
        }
        appendLog("[liveview] 拉流循环结束 generation=\(generation)")
    }

    private func fetchLiveViewFrame(
        on connection: any PTPChannel,
        priority: OperationPriority
    ) async throws -> LiveViewFrame? {
        let preferred: [PTPOperationCode] = supportsOperation(.getLiveViewImageEx)
            ? [.getLiveViewImageEx, .getLiveViewImage]
            : [.getLiveViewImage, .getLiveViewImageEx]
        var lastCode: UInt16 = 0
        for code in preferred where supportsOperation(code) || code == .getLiveViewImage {
            // Always allow 0x9203 attempt even if DeviceInfo omitted it; some bodies still answer.
            // 拉帧用后台优先级：图库缩略图、状态刷新可以随时插队。
            let response = try await operation(
                code,
                parameters: [],
                dataPhase: .receive,
                on: connection,
                logStyle: .silent,
                priority: priority
            )
            lastCode = response.code
            if response.code == PTPResponseCode.deviceBusy.rawValue {
                try await Task.sleep(for: .milliseconds(40))
                return nil
            }
            guard response.code == PTPResponseCode.ok.rawValue, let data = response.data, data.count > 64 else {
                continue
            }
            // JPEG 解码放到主线程之外：解码是刷新率的最大瓶颈。
            if let image = await Self.decodeLiveViewJPEG(from: data) {
                return LiveViewFrame(
                    image: image,
                    focusMetadata: NikonLiveViewFocusMetadata(
                        liveViewData: data,
                        hasVersion: code == .getLiveViewImageEx
                    )
                )
            }
            appendLog("[liveview] \(code.debugName) 返回数据无法解码 bytes=\(data.count)")
        }
        if lastCode != 0, lastCode != PTPResponseCode.ok.rawValue, lastCode != PTPResponseCode.deviceBusy.rawValue {
            throw CameraConnectionError.ptpResponse(lastCode)
        }
        return nil
    }

    private func applyLiveViewFrame(_ frame: LiveViewFrame) {
        liveViewImage = frame.image
        liveViewFocusMetadata = frame.focusMetadata
        liveViewFocusPoint = frame.focusMetadata?.displayedFocusPoint
        isLiveViewFocusPointAvailable = supportsOperation(.changeAfArea)
            && frame.focusMetadata?.isFocusAreaChangeable == true
    }

    /// Move the Nikon live-view AF area, then read a fresh frame so the UI shows
    /// the position that the camera actually accepted.
    @discardableResult
    func setLiveViewFocusPoint(normalizedToDisplayedImage point: CGPoint) async -> Bool {
        guard case .connected = state,
              isLiveViewActive,
              isLiveViewFocusPointAvailable,
              !isSettingLiveViewFocusPoint,
              supportsOperation(.changeAfArea),
              let channel = commandChannel,
              let metadata = liveViewFocusMetadata
        else { return false }

        let cameraPoint = metadata.cameraPoint(forDisplayedPoint: point)
        isSettingLiveViewFocusPoint = true
        defer { isSettingLiveViewFocusPoint = false }

        do {
            let response = try await operation(
                .changeAfArea,
                parameters: [
                    UInt32(cameraPoint.x.rounded()),
                    UInt32(cameraPoint.y.rounded())
                ],
                dataPhase: nil,
                on: channel,
                logStyle: .compact,
                priority: .foreground,
                timeout: .seconds(5)
            )
            guard response.code == PTPResponseCode.ok.rawValue else {
                throw CameraConnectionError.ptpResponse(response.code)
            }

            appendLog(
                "[liveview] ChangeAfArea 成功 x=\(Int(cameraPoint.x.rounded())) " +
                    "y=\(Int(cameraPoint.y.rounded()))"
            )
            for _ in 0..<4 {
                if let frame = try await fetchLiveViewFrame(
                    on: channel,
                    priority: .foreground
                ) {
                    applyLiveViewFrame(frame)
                    return true
                }
                try await Task.sleep(for: .milliseconds(60))
            }
            return true
        } catch {
            appendLog("[liveview] ChangeAfArea 失败 error=\(error.localizedDescription)")
            return false
        }
    }

    /// 后台线程解码并立即展开位图，避免每帧在主线程做昂贵的 JPEG 解码。
    private nonisolated static func decodeLiveViewJPEG(from data: Data) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            let payload = jpegPayload(from: data) ?? data
            guard let source = CGImageSourceCreateWithData(payload as CFData, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else {
                return UIImage(data: data)
            }
            return UIImage(cgImage: cgImage)
        }.value
    }

    /// 机身返回的对象可能带私有头，截取 SOI..EOI 之间的 JPEG 数据。
    private nonisolated static func jpegPayload(from data: Data) -> Data? {
        guard let soi = data.range(of: Data([0xff, 0xd8])) else { return nil }
        if let eoi = data.range(of: Data([0xff, 0xd9]), options: [], in: soi.lowerBound..<data.endIndex) {
            return Data(data[soi.lowerBound..<eoi.upperBound])
        }
        return Data(data[soi.lowerBound...])
    }

    private func operation(
        _ code: PTPOperationCode,
        parameters: [UInt32],
        dataPhase: DataPhase?,
        on connection: any PTPChannel,
        logStyle: OperationLogStyle = .verbose,
        priority: OperationPriority = .foreground,
        timeout: Duration? = nil
    ) async throws -> PTPResponse {
        await acquireOperationSlot(priority: priority)

        let currentTransactionID = max(transactionID &+ 1, 1)
        transactionID = currentTransactionID
        activeOperationTransactionID = currentTransactionID
        let timeoutTask = timeout.map { timeout in
            Task { [weak self] in
                guard let self else { return }
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
                guard self.linkKind == .wifi else { return }
                connection.close()
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
                let end = min(offset + 65536, bytes.count)
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

    private func send(_ packet: Data, on connection: any PTPChannel, logStyle: OperationLogStyle = .verbose) async throws {
        switch logStyle {
        case .verbose:
            appendLog("发送 PTP/IP type=\(packet.packetTypeName) totalBytes=\(packet.count) hex=\(packet.hexDump)")
        case .compact:
            appendLog("发送 PTP/IP type=\(packet.packetTypeName) totalBytes=\(packet.count)")
        case .silent:
            break
        }
        try await connection.send(packet: packet)
    }

    private func receivePacket(on connection: any PTPChannel, logStyle: OperationLogStyle = .verbose) async throws -> PTPIPPacket {
        let packet = try await connection.receivePacket()
        switch logStyle {
        case .verbose:
            appendLog("接收 PTP/IP type=\(packet.typeName) payloadBytes=\(packet.payload.count) hex=\(packet.hexDump)")
        case .compact:
            appendLog("接收 PTP/IP type=\(packet.typeName) payloadBytes=\(packet.payload.count)")
        case .silent:
            break
        }
        return packet
    }

    private func disconnectConnections() {
        commandChannel?.close()
        commandChannel = nil
        isUSBPTPReady = false
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

    private func loadGalleryDirectories(on connection: any PTPChannel) async throws -> [GalleryDirectory] {
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
        var successfulStorageEnumerations = 0
        var lastStorageEnumerationError: Error?

        for storageID in storageIDs {
            // Most PTP cameras support filtering handles by Association (folder) format.
            // This avoids fetching ObjectInfo for every photo before the first grid can appear.
            let filteredFolders: [UInt32]?
            do {
                filteredFolders = try await fetchObjectHandles(
                    storageID: storageID,
                    objectFormat: 0x3001,
                    parent: 0xffffffff,
                    on: connection
                )
            } catch {
                filteredFolders = nil
                lastStorageEnumerationError = error
            }
            let usesAssociationFilter = filteredFolders?.isEmpty == false
            var seedHandles: [UInt32] = []
            if usesAssociationFilter {
                seedHandles = filteredFolders ?? []
                successfulStorageEnumerations += 1
                appendLog(
                    "[图库] 使用目录过滤 storageID=0x\(String(format: "%08X", storageID)) folders=\(seedHandles.count)"
                )
            } else {
                do {
                    let root = try await fetchObjectHandles(
                        storageID: storageID,
                        objectFormat: 0,
                        parent: 0xffffffff,
                        on: connection
                    )
                    successfulStorageEnumerations += 1
                    appendLog(
                        "[图库] 目录过滤不可用，回退根目录扫描 storageID=0x\(String(format: "%08X", storageID)) count=\(root.count)"
                    )
                    seedHandles = root
                } catch {
                    lastStorageEnumerationError = error
                    appendLog(
                        "[图库] 存储枚举失败 storageID=0x\(String(format: "%08X", storageID)) " +
                            "error=\(error.localizedDescription)"
                    )
                    continue
                }
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

        if successfulStorageEnumerations == 0, let lastStorageEnumerationError {
            throw lastStorageEnumerationError
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
        on connection: any PTPChannel
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
                if connection.isReady {
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
                let elapsedMilliseconds = elapsedNanoseconds / 1000000
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

    private nonisolated static func makeSkeletonItem(from record: NikonObjectMetadata) -> GalleryItem {
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
        on connection: any PTPChannel,
        generation: Int
    ) async {
        var pendingChanges = 0
        var lastPublish = Date()

        for (index, record) in metadata.records.enumerated() {
            guard isCurrentGalleryLoad(generation, directoryID: directory.id) else { return }
            await resolveMetadataInfo(for: record, on: connection, generation: generation, priority: .background)

            pendingChanges += 1
            let isLast = index == metadata.records.count - 1
            let shouldPublish = isLast || pendingChanges >= 16 || Date().timeIntervalSince(lastPublish) >= 0.35
            if shouldPublish {
                await publishMetadataGallery(generation: generation, directoryID: directory.id)
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
                "objects=\(galleryItems.count) photos=\(photos) videos=\(videos) " +
                "infoErrors=\(metadataAttemptedHandles.count - metadataResolvedItems.count - metadataExcludedHandles.count)"
        )
    }

    /// Resolve a visible skeleton before requesting its thumbnail. A paired item may no longer
    /// have its own grid cell after this publishes the updated list.
    func galleryItemReadyForThumbnail(_ handle: UInt32) async -> GalleryItem? {
        guard let directoryID = metadataDirectoryID,
              let connection = metadataConnection,
              let record = metadataRecordsByHandle[handle]
        else {
            return galleryItems.first { $0.handle == handle }
        }
        let generation = galleryLoadGeneration
        await resolveMetadataInfo(for: record, on: connection, generation: generation, priority: .foreground)
        if let rawItem = metadataResolvedItems[handle], rawItem.rawHandle != nil,
           let captureDate = record.captureDate
        {
            // Nikon pairs normally have neighboring handles and the same capture timestamp.
            let pairKey = Self.photoPairKey(for: rawItem.filename)
            for candidate in metadataRecords where candidate.handle != handle
                && candidate.captureDate == captureDate
                && abs(Int64(candidate.handle) - Int64(handle)) <= 4
            {
                guard isCurrentGalleryLoad(generation, directoryID: directoryID) else { return nil }
                if metadataResolvedItems.values.contains(where: {
                    $0.jpegHandle != nil && Self.photoPairKey(for: $0.filename) == pairKey
                }) { break }
                await resolveMetadataInfo(for: candidate, on: connection, generation: generation, priority: .foreground)
            }
        }
        await publishMetadataGallery(generation: generation, directoryID: directoryID)
        guard isCurrentGalleryLoad(generation, directoryID: directoryID) else { return nil }
        return galleryItems.first { $0.handle == handle }
    }

    private func resolveMetadataInfo(
        for record: NikonObjectMetadata,
        on connection: any PTPChannel,
        generation: Int,
        priority: OperationPriority
    ) async {
        let handle = record.handle
        guard !metadataAttemptedHandles.contains(handle) else { return }
        let task: Task<ParsedObjectInfo?, Never>
        if let existing = metadataInfoTasks[handle] {
            task = existing
        } else {
            task = Task {
                do {
                    return try await fetchObjectInfo(handle: handle, on: connection, priority: priority)
                } catch {
                    appendLog(
                        "[图库] ObjectInfo 跳过 handle=0x\(String(format: "%08X", handle)) " +
                            "error=\(error.localizedDescription)"
                    )
                    return nil
                }
            }
            metadataInfoTasks[handle] = task
        }
        let info = await task.value
        guard isCurrentGalleryLoad(generation, directoryID: metadataDirectoryID),
              !metadataAttemptedHandles.contains(handle) else { return }
        metadataInfoTasks[handle] = nil
        metadataAttemptedHandles.insert(handle)
        metadataRevision &+= 1
        guard let info else { return }
        if isAssociationObject(objectFormat: info.objectFormat)
            || !isGalleryMedia(objectFormat: info.objectFormat, filename: info.filename)
        {
            metadataExcludedHandles.insert(handle)
            return
        }
        let isVideo = isVideoMedia(objectFormat: info.objectFormat, filename: info.filename)
        let isRAW = !isVideo && isRAWMedia(objectFormat: info.objectFormat, filename: info.filename)
        metadataResolvedItems[handle] = GalleryItem(
            id: handle,
            filename: info.filename,
            objectFormat: info.objectFormat,
            fileSize: info.fileSize,
            isVideo: isVideo,
            captureDate: record.captureDate ?? info.captureDate ?? info.modificationDate,
            rawHandle: isRAW ? handle : nil,
            rawFilename: isRAW ? info.filename : nil,
            rawFileSize: isRAW ? info.fileSize : nil,
            jpegHandle: !isVideo && !isRAW ? handle : nil,
            jpegFilename: !isVideo && !isRAW ? info.filename : nil,
            jpegFileSize: !isVideo && !isRAW ? info.fileSize : nil
        )
    }

    private func publishMetadataGallery(generation: Int, directoryID: UInt32) async {
        while isCurrentGalleryLoad(generation, directoryID: directoryID) {
            let revision = metadataRevision
            let records = metadataRecords
            let resolved = metadataResolvedItems
            let excluded = metadataExcludedHandles
            let published = await Task.detached(priority: .utility) {
                Self.buildEnrichedGalleryItems(records: records, resolved: resolved, excludedHandles: excluded)
            }.value
            guard isCurrentGalleryLoad(generation, directoryID: directoryID) else { return }
            guard revision == metadataRevision else { continue }
            if published != galleryItems { galleryItems = published }
            return
        }
    }

    nonisolated static func buildEnrichedGalleryItems(
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
        on connection: any PTPChannel,
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

    private nonisolated static func sortedGalleryItems(_ items: [GalleryItem]) -> [GalleryItem] {
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

    nonisolated static func galleryItemsByAdding(_ item: GalleryItem, to items: [GalleryItem]) -> [GalleryItem] {
        guard items.allSatisfy({
            $0.id != item.id
                && $0.rawHandle != item.id
                && $0.jpegHandle != item.id
        }) else { return items }
        return sortedGalleryItems(mergePairedPhotos(items + [item]))
    }

    nonisolated static func galleryItemsByRemoving(handle: UInt32, from items: [GalleryItem]) -> [GalleryItem] {
        let remaining = items.compactMap { item -> GalleryItem? in
            guard item.id == handle || item.rawHandle == handle || item.jpegHandle == handle else {
                return item
            }
            guard !item.isVideo else { return nil }

            if item.rawHandle == handle, let jpegHandle = item.jpegHandle {
                return GalleryItem(
                    id: jpegHandle,
                    filename: item.jpegFilename ?? item.filename,
                    objectFormat: item.objectFormat,
                    fileSize: item.jpegFileSize ?? 0,
                    isVideo: false,
                    captureDate: item.captureDate,
                    rawHandle: nil,
                    rawFilename: nil,
                    rawFileSize: nil,
                    jpegHandle: jpegHandle,
                    jpegFilename: item.jpegFilename ?? item.filename,
                    jpegFileSize: item.jpegFileSize
                )
            }
            if item.jpegHandle == handle, let rawHandle = item.rawHandle {
                return GalleryItem(
                    id: rawHandle,
                    filename: item.rawFilename ?? item.filename,
                    objectFormat: 0xb802,
                    fileSize: item.rawFileSize ?? 0,
                    isVideo: false,
                    captureDate: item.captureDate,
                    rawHandle: rawHandle,
                    rawFilename: item.rawFilename ?? item.filename,
                    rawFileSize: item.rawFileSize,
                    jpegHandle: nil,
                    jpegFilename: nil,
                    jpegFileSize: nil
                )
            }
            return nil
        }
        return sortedGalleryItems(remaining)
    }

    private nonisolated static func mergePairedPhotos(_ sourceItems: [GalleryItem]) -> [GalleryItem] {
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

    private nonisolated static func combinePhotoItems(_ lhs: GalleryItem, _ rhs: GalleryItem) -> GalleryItem {
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

    private nonisolated static func photoPairKey(for filename: String) -> String {
        let base = (filename as NSString).deletingPathExtension
        return base.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private func fetchStorageIDs(on connection: any PTPChannel) async throws -> [UInt32] {
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
        on connection: any PTPChannel
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
        var storageID: UInt32
        var objectFormat: UInt16
        var fileSize: UInt64
        var parentObject: UInt32
        var filename: String
        var captureDate: Date?
        var modificationDate: Date?
    }

    private func fetchObjectInfo(
        handle: UInt32,
        on connection: any PTPChannel,
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
            storageID: data.uint32(at: 0),
            objectFormat: objectFormat,
            fileSize: fileSize,
            parentObject: data.uint32(at: 38),
            filename: filename.value,
            captureDate: parsePTPDateTime(captureDate.value),
            modificationDate: parsePTPDateTime(modificationDate.value)
        )
    }

    private func makeGalleryItem(handle: UInt32, info: ParsedObjectInfo) -> GalleryItem {
        let isVideo = isVideoMedia(objectFormat: info.objectFormat, filename: info.filename)
        let isRAW = !isVideo && isRAWMedia(objectFormat: info.objectFormat, filename: info.filename)
        return GalleryItem(
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
        if objectFormat == 0xb802 || objectFormat == 0xb80a {
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

    private func readCameraStatus(on connection: any PTPChannel) async -> CameraStatus {
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

        if let storageIDs = try? await fetchStorageIDs(on: connection) {
            var totalObjectCount = 0
            var didReadObjectCount = false

            for (index, storageID) in storageIDs.enumerated() {
                if let response = try? await operation(
                    .getStorageInfo,
                    parameters: [storageID],
                    dataPhase: .receive,
                    on: connection,
                    logStyle: .silent
                ), response.code == PTPResponseCode.ok.rawValue,
                let data = response.data,
                let storage = parseStorageInfo(data, storageID: storageID, index: index) {
                    status.storages.append(storage)
                }

                if let numberOfObjects = try? await operation(
                    .getNumObjects,
                    parameters: [storageID, 0, 0],
                    dataPhase: .receive,
                    on: connection
                ), numberOfObjects.code == PTPResponseCode.ok.rawValue,
                let objectData = numberOfObjects.data,
                objectData.count >= 4 {
                    totalObjectCount += Int(objectData.uint32(at: 0))
                    didReadObjectCount = true
                }
            }

            if didReadObjectCount {
                status.mediaObjectCount = totalObjectCount
            }
        }

        return status
    }

    private func parseStorageInfo(_ data: Data, storageID: UInt32, index: Int) -> StorageInfo? {
        // PTP StorageInfo dataset: 3 UInt16 fields, 2 UInt64 fields,
        // FreeSpaceInImages (UInt32), StorageDescription and VolumeLabel.
        guard data.count >= 26 else { return nil }

        let totalBytes = data.uint64(at: 6)
        let freeBytes = min(data.uint64(at: 14), totalBytes)
        let freeImageCount = data.uint32(at: 22)
        var description = ""
        var volumeLabel = ""

        if data.count > 26,
           let parsedDescription = try? readPTPString(from: data, offset: 26)
        {
            description = parsedDescription.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if parsedDescription.nextOffset < data.count,
               let parsedVolumeLabel = try? readPTPString(from: data, offset: parsedDescription.nextOffset)
            {
                volumeLabel = parsedVolumeLabel.value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        let name = !description.isEmpty ? description : (!volumeLabel.isEmpty ? volumeLabel : "卡槽\(index + 1)")
        return StorageInfo(
            id: storageID,
            name: name,
            totalBytes: totalBytes,
            freeBytes: freeBytes,
            freeImageCount: freeImageCount == UInt32.max ? nil : freeImageCount
        )
    }

    private func readLensInfo(on connection: any PTPChannel) async -> LensInfo {
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
        on connection: any PTPChannel
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
            let data = response.data
        else {
            return nil
        }
        return readIntegerValue(from: data)
    }

    private func readCapturePropertyDescription(
        for parameter: CaptureParameter,
        on connection: any PTPChannel
    ) async -> CapturePropertyDescription? {
        let propertyCodes = [parameter.rawValue, parameter.fallbackPropertyCode]
            .compactMap { $0 }
        var firstDescription: CapturePropertyDescription?

        for propertyCode in propertyCodes {
            guard let description = await readDevicePropertyDescription(
                propertyCode,
                on: connection
            ) else { continue }
            if firstDescription == nil {
                firstDescription = description
            }
            if description.isWritable, !description.allowedValues.isEmpty {
                return description
            }
        }
        return firstDescription
    }

    private func readDevicePropertyDescription(
        _ propertyCode: UInt16,
        on connection: any PTPChannel
    ) async -> CapturePropertyDescription? {
        guard let response = try? await operation(
            .getDevicePropDesc,
            parameters: [UInt32(propertyCode)],
            dataPhase: .receive,
            on: connection,
            logStyle: .compact,
            timeout: .seconds(4)
        ) else {
            appendLog(
                "[capture] GetDevicePropDesc 请求异常 property=0x" +
                    String(format: "%04X", propertyCode)
            )
            return nil
        }

        guard response.code == PTPResponseCode.ok.rawValue, let data = response.data else {
            appendLog(
                "[capture] GetDevicePropDesc 失败 property=0x" +
                    String(format: "%04X", propertyCode) +
                    " code=0x" + String(format: "%04X", response.code)
            )
            return nil
        }

        guard let description = CapturePropertyDescriptionParser.parse(
            data,
            expectedPropertyCode: propertyCode
        ) else {
            appendLog(
                "[capture] GetDevicePropDesc 无法解析 property=0x" +
                    String(format: "%04X", propertyCode) +
                    " bytes=\(data.count) hex=\(data.hexDump)"
            )
            return nil
        }
        return description
    }

    private func appendCapturePropertyDescriptionLog(
        parameter: CaptureParameter,
        description: CapturePropertyDescription,
        optionCount: Int
    ) {
        let formDescription: String
        switch description.form {
        case .none:
            formDescription = "none"
        case .range(let minimum, let maximum, let step):
            formDescription = "range min=\(captureHex(minimum)) max=\(captureHex(maximum)) step=\(captureHex(step))"
        case .enumeration(let values):
            formDescription = "enum values=[\(values.map(captureHex).joined(separator: ","))]"
        }
        appendLog(
            "[capture] 可设置值 name=\(parameter.title) property=0x" +
                String(format: "%04X", description.propertyCode) +
                " type=0x" + String(format: "%04X", description.dataType.rawValue) +
                " writable=\(description.isWritable) current=\(captureHex(description.currentValue)) " +
                "form=\(formDescription) options=\(optionCount)"
        )
    }

    private func captureHex(_ value: UInt64) -> String {
        String(format: "0x%04llX", value)
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
            ("ChangeAfArea", PTPOperationCode.changeAfArea.rawValue),
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

private struct LiveViewFrame {
    let image: UIImage
    let focusMetadata: NikonLiveViewFocusMetadata?
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

enum PTPOperationCode: UInt16 {
    case getDeviceInfo = 0x1001
    case openSession = 0x1002
    case getStorageIDs = 0x1004
    case getStorageInfo = 0x1005
    case getNumObjects = 0x1006
    case getObjectHandles = 0x1007
    case getObjectInfo = 0x1008
    case getObject = 0x1009
    case getThumb = 0x100a
    case deleteObject = 0x100b
    case getPartialObject = 0x101b
    case getDevicePropValue = 0x1015
    case getDevicePropDesc = 0x1014
    case setDevicePropValue = 0x1016
    case getObjectPropValue = 0x9803
    case autoFocusDrive = 0x90c1
    case deviceReady = 0x90c8
    case getPreviewImage = 0x9200
    case startLiveView = 0x9201
    case endLiveView = 0x9202
    case getLiveViewImage = 0x9203
    case changeAfArea = 0x9205
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
        case .deleteObject: return "DeleteObject"
        case .getPartialObject: return "GetPartialObject"
        case .getDevicePropValue: return "GetDevicePropValue"
        case .getDevicePropDesc: return "GetDevicePropDesc"
        case .setDevicePropValue: return "SetDevicePropValue"
        case .getObjectPropValue: return "GetObjectPropValue"
        case .autoFocusDrive: return "AfDrive"
        case .deviceReady: return "DeviceReady"
        case .getPreviewImage: return "GetPreviewImg"
        case .startLiveView: return "StartLiveView"
        case .endLiveView: return "EndLiveView"
        case .getLiveViewImage: return "GetLiveViewImg"
        case .changeAfArea: return "ChangeAfArea"
        case .initiateCaptureRecInMedia: return "InitiateCaptureRecInMedia"
        case .getLiveViewImageEx: return "GetLiveViewImageEx"
        case .getObjectsMetadata: return "GetObjectsMetaData"
        case .changeApplicationMode: return "ChangeApplicationMode"
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

private extension Data {
    func cgFloat16(at offset: Int) -> CGFloat {
        CGFloat(Int(uint16(at: offset)))
    }
}
