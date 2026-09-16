//
//  USBCameraLink.swift
//  ZLinks
//
//  USB 有线连接。通过 ImageCaptureCore 访问 USB 上的 PTP 相机，一次连接同时提供两条通道：
//
//  1. PTP 直通通道（ICCameraDevice.requestSendPTPCommand）
//     相机信息、机身参数、实时图传、图库对象读取全部走 USB。为了不重新实现一遍协议，
//     这里把 PTP/IP 报文翻译成 PTP 容器后交给系统发送，上层 CameraConnectionService
//     的报文解析、事务号、超时逻辑完全复用 Wi-Fi 分支。
//
//  2. 内容目录通道（ImageCaptureCore 目录 + requestThumbnailData / requestReadData）
//     图库列表、缩略图、原图下载走系统优化的 USB 通路，避免逐条 PTP 轮询。
//

import Combine
import Foundation
import ImageCaptureCore
import UIKit

/// ImageCaptureCore 报告的 USB 相机。
struct USBCameraDescriptor: Identifiable, Equatable {
    let id: String
    let name: String
    let model: String
    let serialNumber: String
    let vendorID: Int32
    let productID: Int32
    let locationID: Int32

    var title: String {
        let model = self.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !model.isEmpty { return model }
        let name = self.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "USB 相机" : name
    }

    var subtitle: String {
        var parts: [String] = []
        let serial = serialNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        if !serial.isEmpty { parts.append("序列号 \(serial)") }
        parts.append(
            String(
                format: "USB %04X:%04X",
                UInt32(bitPattern: vendorID),
                UInt32(bitPattern: productID)
            )
        )
        return parts.joined(separator: " · ")
    }

    var manufacturerName: String {
        vendorID == 0x04B0 ? "Nikon Corporation" : "USB Camera"
    }
}

/// 相机内容目录的扁平化快照。CameraConnectionService 负责把它映射成图库条目。
struct USBCameraCatalog {
    struct Entry: Equatable {
        let handle: UInt32
        let filename: String
        let fileSize: UInt64
        let captureDate: Date?
        let isRAW: Bool
        let isVideo: Bool
    }

    struct Folder: Equatable {
        let handle: UInt32
        let storageID: UInt32
        let name: String
        let path: String
        let isSyntheticRoot: Bool
        let entries: [Entry]
    }

    let folders: [Folder]

    static let empty = USBCameraCatalog(folders: [])

    var objectCount: Int {
        folders.reduce(0) { $0 + $1.entries.count }
    }

    var isEmpty: Bool { objectCount == 0 }
}

/// PTP 命令容器的拼装方式。不同系统版本对是否包含 4 字节长度字段的要求不同，
/// 连接时根据相机实际响应自动选定。
enum USBPTPFraming: String {
    case standard
    case lengthLess
}

enum USBPTPContainerKind: UInt16 {
    case command = 1
    case data = 2
    case response = 3
}

/// 一次 USB PTP 事务的结果，已按容器类型拆分。
struct USBPTPTransactionResult {
    let code: UInt16
    let transactionID: UInt32
    let parameters: [UInt32]
    let data: Data
    let dataMode: USBPTPDataMode
}

enum USBPTPDataMode: String {
    case none
    case container
    case raw
}

@MainActor
final class USBCameraLink: ObservableObject {
    @Published private(set) var cameras: [USBCameraDescriptor] = []
    @Published private(set) var isBrowsing = false
    @Published private(set) var isSessionOpen = false
    @Published private(set) var statusMessage = "使用 USB 数据线连接相机后自动检测"
    @Published private(set) var catalogProgress: Double = 0
    @Published private(set) var connectedDeviceID: String?
    @Published private(set) var connectedDeviceTitle: String?
    @Published private(set) var isPTPReady = false

    /// 相机被拔出或系统关闭会话时回调，由 CameraConnectionService 处理断线。
    var deviceDisconnectedHandler: ((String) -> Void)?
    var logHandler: ((String) -> Void)?

    private let browser = ICDeviceBrowser()
    private lazy var proxy = USBCameraProxy(link: self)
    private var devicesByID: [String: ICCameraDevice] = [:]
    private var activeDevice: ICCameraDevice?
    private var filesByHandle: [UInt32: ICCameraFile] = [:]
    private var catalog = USBCameraCatalog.empty
    private var catalogDidComplete = false
    private var intentionallyClosingDevices: Set<ObjectIdentifier> = []
    private var framing: USBPTPFraming = .standard
    private var discoveryTask: Task<Void, Never>?

    // MARK: - 设备发现

    func startDiscovery() {
        guard !browser.isBrowsing else {
            isBrowsing = true
            log("[usb][discovery] 扫描已在运行 devices=\(browser.devices?.count ?? 0)")
            return
        }
        guard discoveryTask == nil else {
            log("[usb][discovery] 正在等待内容访问授权")
            return
        }
        isBrowsing = true
        statusMessage = "正在检查 USB 相机访问权限"
        log(
            "[usb][discovery] 开始扫描前检查 contentsAuth=\(Self.authorizationDescription(browser.contentsAuthorizationStatus)) " +
                "controlAuth=\(Self.authorizationDescription(browser.controlAuthorizationStatus))"
        )
        discoveryTask = Task { [weak self] in
            guard let self else { return }
            let authorization = await self.browser.requestContentsAuthorization()
            guard !Task.isCancelled else { return }
            self.log("[usb][discovery] 内容授权结果 status=\(Self.authorizationDescription(authorization)) raw=\(authorization.rawValue)")
            guard authorization == .authorized else {
                self.isBrowsing = false
                self.statusMessage = "未获得读取 USB 相机内容的权限"
                self.log("[usb][discovery] 扫描终止 stage=authorization")
                self.discoveryTask = nil
                return
            }

            self.browser.delegate = self.proxy
            self.browser.browsedDeviceTypeMask = ICDeviceTypeMask(
                rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue
            ) ?? .camera
            self.log(
                "[usb][discovery] 启动 ICDeviceBrowser mask=0x" +
                    String(format: "%08X", self.browser.browsedDeviceTypeMask.rawValue)
            )
            self.browser.start()
            self.log("[usb][discovery] browser.start 完成 isBrowsing=\(self.browser.isBrowsing)")
            for device in self.browser.devices ?? [] {
                self.forwardDeviceAdded(device, source: "initial", moreComing: false)
            }
            self.log("[usb][discovery] 初始设备快照 count=\(self.browser.devices?.count ?? 0)")
            self.discoveryTask = nil
            self.refreshStatusMessage()
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let self, self.browser.isBrowsing, self.cameras.isEmpty else { return }
                self.log(
                    "[usb][discovery] 3 秒内未收到设备回调；故障位于系统 USB 枚举层，" +
                        "尚未进入 MTP/PTP 会话。请检查相机 USB=MTP/PTP、数据线、转接器与供电"
                )
            }
        }
    }

    func stopDiscovery() {
        discoveryTask?.cancel()
        discoveryTask = nil
        if activeDevice != nil || connectedDeviceID != nil {
            isBrowsing = false
            log(
                "[usb][discovery] 连接页关闭，保留活动 browser/session " +
                    "device=\(connectedDeviceTitle ?? activeDevice?.name ?? "--")"
            )
            return
        }
        log(
            "[usb][discovery] 停止扫描 browserActive=\(browser.isBrowsing) " +
                "browserDevices=\(browser.devices?.count ?? 0) cameras=\(cameras.count)"
        )
        if browser.isBrowsing {
            browser.stop()
        }
        isBrowsing = false
        cameras = []
        if connectedDeviceID == nil {
            statusMessage = "已停止 USB 检测"
        }
    }

    func register(_ device: ICCameraDevice) {
        let descriptor = Self.makeDescriptor(device)
        devicesByID[descriptor.id] = device
        if let index = cameras.firstIndex(where: { $0.id == descriptor.id }) {
            cameras[index] = descriptor
        } else {
            cameras.append(descriptor)
        }
        cameras.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        log(
            "[usb][discovery] 相机已登记 id=\(descriptor.id) title=\(descriptor.title) " +
                "vid=0x\(String(format: "%04X", UInt32(bitPattern: descriptor.vendorID))) " +
                "pid=0x\(String(format: "%04X", UInt32(bitPattern: descriptor.productID))) cameras=\(cameras.count)"
        )
        refreshStatusMessage()
    }

    func unregister(_ device: ICDevice) {
        let identifier = Self.identifier(for: device)
        log("[usb][discovery] 设备移除 id=\(identifier) name=\(device.name ?? "--")")
        devicesByID[identifier] = nil
        cameras.removeAll { $0.id == identifier }
        refreshStatusMessage()
        guard connectedDeviceID == identifier else { return }
        let title = connectedDeviceTitle ?? "USB 相机"
        resetSession(reason: "\(title) 的 USB 连接已断开")
    }

    // MARK: - 会话

    /// 打开 USB 会话并准备好两条数据通道。失败时抛出可直接展示给用户的错误。
    func open(_ descriptor: USBCameraDescriptor, loadContentCatalog: Bool = true) async throws {
        closeSession()
        guard let device = devicesByID[descriptor.id] else {
            throw CameraConnectionError.usbUnavailable("未检测到该 USB 相机，请重新插拔数据线后重试")
        }

        activeDevice = device
        connectedDeviceID = descriptor.id
        connectedDeviceTitle = descriptor.title
        device.delegate = proxy
        log("[usb][session] 准备打开 device=\(descriptor.title) \(descriptor.subtitle)")
        log("[usb][session] \(Self.deviceDiagnosticDescription(device))")

        let contentsAuthorization = await browser.requestContentsAuthorization()
        log("[usb][session] 内容授权 status=\(Self.authorizationDescription(contentsAuthorization)) raw=\(contentsAuthorization.rawValue)")
        guard contentsAuthorization == .authorized else {
            throw CameraConnectionError.usbUnavailable("未获得读取相机内容的权限，请在系统设置中允许后重试")
        }

        let controlAuthorization = await browser.requestControlAuthorization()
        log("[usb][session] 控制授权 status=\(Self.authorizationDescription(controlAuthorization)) raw=\(controlAuthorization.rawValue)")
        guard controlAuthorization == .authorized else {
            throw CameraConnectionError.usbUnavailable("未获得控制相机的权限，请在系统设置中允许后重试")
        }

        if !device.hasOpenSession {
            log("[usb][session] 请求打开 ImageCaptureCore 会话")
            try await device.requestOpenSession()
        } else {
            log("[usb][session] 复用已打开的 ImageCaptureCore 会话")
        }
        try await waitForSession(device)
        isSessionOpen = true
        log("[usb][session] 会话已建立 hasOpenSession=\(device.hasOpenSession)")

        if loadContentCatalog {
            _ = try await loadCatalogSnapshot()
        } else {
            statusMessage = "正在建立 PTP 连接"
            log("[usb][session] 快速连接已开启，跳过内容目录等待")
        }

        do {
            try await negotiateFraming(device)
            isPTPReady = true
        } catch {
            isPTPReady = false
            log("[usb][ptp] 直通不可用 error=\(String(reflecting: error)) description=\(error.localizedDescription)")
        }
    }

    func closeSession() {
        guard let device = activeDevice else {
            resetSessionState()
            return
        }
        log("[usb][session] 关闭会话 hasOpenSession=\(device.hasOpenSession) device=\(device.name ?? "--")")
        if device.hasOpenSession {
            let identifier = ObjectIdentifier(device)
            intentionallyClosingDevices.insert(identifier)
            device.requestCloseSession()
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                self?.intentionallyClosingDevices.remove(identifier)
            }
        }
        device.delegate = nil
        resetSessionState()
    }

    private func resetSessionState() {
        isSessionOpen = false
        isPTPReady = false
        catalog = .empty
        catalogDidComplete = false
        catalogProgress = 0
        filesByHandle = [:]
        activeDevice = nil
        connectedDeviceID = nil
        connectedDeviceTitle = nil
        framing = .standard
    }

    private func resetSession(reason: String) {
        log("[usb] \(reason)")
        let wasConnected = connectedDeviceID != nil
        resetSessionState()
        if wasConnected {
            deviceDisconnectedHandler?(reason)
        }
    }

    private func handleSessionClosed(device: ICDevice, reason: String) {
        let identifier = ObjectIdentifier(device)
        if intentionallyClosingDevices.remove(identifier) != nil {
            log("[usb][session] 忽略主动关闭完成回调 device=\(device.name ?? "--")")
            return
        }
        guard activeDevice === device else {
            log("[usb][session] 忽略非活动设备的会话关闭回调 device=\(device.name ?? "--")")
            return
        }
        guard connectedDeviceID != nil else { return }
        resetSession(reason: reason)
    }

    private func waitForSession(_ device: ICCameraDevice) async throws {
        let deadline = Date().addingTimeInterval(20)
        log("[usb][session] 等待会话就绪 timeout=20s")
        while Date() < deadline {
            if device.hasOpenSession { return }
            if Task.isCancelled { throw CameraConnectionError.connectionCancelled }
            try? await Task.sleep(for: .milliseconds(120))
        }
        log("[usb][session] 会话等待超时 hasOpenSession=\(device.hasOpenSession)")
        throw CameraConnectionError.usbUnavailable("相机未响应 USB 会话请求，请重新插拔数据线后重试")
    }

    private func waitForCatalog(_ device: ICCameraDevice) async throws {
        let deadline = Date().addingTimeInterval(12)
        var reachedCompletion = false
        let initialProgress = max(0, min(device.contentCatalogPercentCompleted, 100))
        statusMessage = "正在读取相机内容（\(initialProgress)%）"
        log("[usb][session] 等待内容目录 timeout=12s initialProgress=\(initialProgress)%")
        while Date() < deadline {
            guard activeDevice === device, device.hasOpenSession else {
                log("[usb][session] 内容目录等待中止 reason=会话已关闭")
                throw CameraConnectionError.connectionCancelled
            }
            if catalogDidComplete {
                reachedCompletion = true
                break
            }
            let progress = Double(max(0, min(device.contentCatalogPercentCompleted, 100))) / 100
            if progress != catalogProgress {
                catalogProgress = progress
                statusMessage = "正在读取相机内容（\(Int(progress * 100))%）"
            }
            if progress >= 1 {
                reachedCompletion = true
                break
            }
            if Task.isCancelled { throw CameraConnectionError.connectionCancelled }
            try await Task.sleep(for: .milliseconds(150))
        }
        if !reachedCompletion {
            log(
                "[usb][session] 内容目录等待结束但未收到完成信号 progress=" +
                    "\(device.contentCatalogPercentCompleted)% cancelled=\(Task.isCancelled)"
            )
        }
        catalogDidComplete = true
        catalogProgress = 1
        statusMessage = reachedCompletion ? "相机内容读取完成" : "相机内容仍在后台读取"
    }

    // MARK: - PTP 直通

    /// 用极小的 PTP 往返确认容器拼装方式，避免把错误的帧格式带进正式会话。
    private func negotiateFraming(_ device: ICCameraDevice) async throws {
        var failures: [String] = []
        for candidate in [USBPTPFraming.standard, .lengthLess] {
            framing = candidate
            log("[usb][ptp] 探测 framing=\(candidate.rawValue)")
            do {
                let session = try await sendRaw(
                    on: device,
                    code: PTPOperationCode.openSession.rawValue,
                    transactionID: 0xFFFF_FF00,
                    parameters: [1],
                    outgoingData: nil
                )
                guard session.code == PTPResponseCode.ok.rawValue
                    || session.code == PTPResponseCode.sessionAlreadyOpen.rawValue
                else {
                    log(
                        "[usb][ptp] 探测 OpenSession 被拒绝 framing=\(candidate.rawValue) " +
                            "code=0x\(String(format: "%04X", session.code))"
                    )
                    failures.append("\(candidate.rawValue) OpenSession 0x\(String(format: "%04X", session.code))")
                    continue
                }

                let info = try await sendRaw(
                    on: device,
                    code: PTPOperationCode.getDeviceInfo.rawValue,
                    transactionID: 0xFFFF_FF01,
                    parameters: [],
                    outgoingData: nil
                )
                guard info.code == PTPResponseCode.ok.rawValue, info.data.count > 20 else {
                    log(
                        "[usb][ptp] 探测 GetDeviceInfo 失败 framing=\(candidate.rawValue) " +
                            "code=0x\(String(format: "%04X", info.code)) bytes=\(info.data.count)"
                    )
                    failures.append(
                        "\(candidate.rawValue) GetDeviceInfo 0x\(String(format: "%04X", info.code)) bytes=\(info.data.count)"
                    )
                    continue
                }
                log("[usb] PTP 直通就绪 framing=\(candidate.rawValue) deviceInfoBytes=\(info.data.count)")
                return
            } catch {
                log(
                    "[usb][ptp] 探测传输异常 framing=\(candidate.rawValue) " +
                        "error=\(String(reflecting: error))"
                )
                failures.append("\(candidate.rawValue) \(error.localizedDescription)")
            }
        }
        throw CameraConnectionError.usbUnavailable(
            failures.isEmpty ? "相机未响应 PTP 指令" : failures.joined(separator: " / ")
        )
    }

    func performTransaction(
        code: UInt16,
        transactionID: UInt32,
        parameters: [UInt32],
        outgoingData: Data?
    ) async throws -> USBPTPTransactionResult {
        guard let device = activeDevice, isSessionOpen else {
            throw CameraConnectionError.connectionCancelled
        }
        return try await sendRaw(
            on: device,
            code: code,
            transactionID: transactionID,
            parameters: parameters,
            outgoingData: outgoingData
        )
    }

    private func sendRaw(
        on device: ICCameraDevice,
        code: UInt16,
        transactionID: UInt32,
        parameters: [UInt32],
        outgoingData: Data?
    ) async throws -> USBPTPTransactionResult {
        let command = makeCommandContainer(code: code, transactionID: transactionID, parameters: parameters)
        let parameterText = parameters.map { String(format: "0x%08X", $0) }.joined(separator: ",")
        log(
            "[usb][ptp] send opcode=0x\(String(format: "%04X", code)) tx=\(transactionID) " +
                "framing=\(framing.rawValue) params=[\(parameterText)] commandBytes=\(command.count) " +
                "outBytes=\(outgoingData?.count ?? 0) outMode=raw"
        )
        do {
            // ImageCaptureCore accepts the command container and data-phase dataset separately.
            // Wrapping outData in another PTP data container corrupts SetDevicePropValue payloads.
            let (first, second) = try await device.requestSendPTPCommand(command, outData: outgoingData)
            let firstProbe = Self.probeContainer(first)
            let secondProbe = Self.probeContainer(second)
            let result = Self.decodeTransaction(
                first: first,
                second: second,
                fallbackTransactionID: transactionID,
                fallbackCode: PTPResponseCode.ok.rawValue
            )
            log(
                "[usb][ptp] recv opcode=0x\(String(format: "%04X", code)) tx=\(transactionID) " +
                    "first=\(Self.containerDescription(firstProbe.kind))/\(first.count)B " +
                    "second=\(Self.containerDescription(secondProbe.kind))/\(second.count)B " +
                    "responseFound=\(firstProbe.kind == .response || secondProbe.kind == .response) " +
                    "code=0x\(String(format: "%04X", result.code)) dataBytes=\(result.data.count) " +
                    "dataMode=\(result.dataMode.rawValue)"
            )
            if result.dataMode != .raw,
               (firstProbe.kind == nil && !first.isEmpty) || (secondProbe.kind == nil && !second.isEmpty)
            {
                log(
                    "[usb][ptp] 未识别容器 firstHex=\(first.hexDump) secondHex=\(second.hexDump)"
                )
            }
            return result
        } catch {
            log(
                "[usb][ptp] transportError opcode=0x\(String(format: "%04X", code)) tx=\(transactionID) " +
                    "error=\(String(reflecting: error)) description=\(error.localizedDescription)"
            )
            throw error
        }
    }

    private func makeCommandContainer(code: UInt16, transactionID: UInt32, parameters: [UInt32]) -> Data {
        var body = Data()
        body.append(uint16Data(USBPTPContainerKind.command.rawValue))
        body.append(uint16Data(code))
        body.append(uint32Data(transactionID))
        for parameter in parameters {
            body.append(uint32Data(parameter))
        }
        return applyLengthPrefix(to: body)
    }

    private func applyLengthPrefix(to body: Data) -> Data {
        switch framing {
        case .standard:
            return uint32Data(UInt32(body.count + 4)) + body
        case .lengthLess:
            return body
        }
    }

    // MARK: - 容器解析

    /// 系统回调回来的两个 Data 分别可能是「响应容器」和「数据容器」，顺序在不同版本上不一致，
    /// 因此按容器类型判定，而不是按参数位置假定。
    static func decodeTransaction(
        first: Data,
        second: Data,
        fallbackTransactionID: UInt32,
        fallbackCode: UInt16
    ) -> USBPTPTransactionResult {
        let firstProbe = probeContainer(first)
        let secondProbe = probeContainer(second)

        // ImageCaptureCore may rewrite transaction IDs, so the response cannot be
        // validated against the ID sent by the app. Prefer an unambiguous standard
        // response container before considering the lengthless form.
        var responseContainer: Data?
        var responseOffset = 4
        var responseIsFirst = false
        var responseIsSecond = false
        if firstProbe.kind == .response, firstProbe.offset == 4 {
            responseContainer = first
            responseOffset = firstProbe.offset
            responseIsFirst = true
        } else if secondProbe.kind == .response, secondProbe.offset == 4 {
            responseContainer = second
            responseOffset = secondProbe.offset
            responseIsSecond = true
        } else if firstProbe.kind == .response {
            responseContainer = first
            responseOffset = firstProbe.offset
            responseIsFirst = true
        } else if secondProbe.kind == .response {
            responseContainer = second
            responseOffset = secondProbe.offset
            responseIsSecond = true
        }

        var code = fallbackCode
        var transactionID = fallbackTransactionID
        var parameters: [UInt32] = []
        if let responseContainer, responseContainer.count >= responseOffset + 8 {
            code = responseContainer.uint16(at: responseOffset + 2)
            transactionID = responseContainer.uint32(at: responseOffset + 4)
            var cursor = responseOffset + 8
            while cursor + 4 <= responseContainer.count {
                parameters.append(responseContainer.uint32(at: cursor))
                cursor += 4
            }
        }

        // Standard data containers are self-validating through their length field.
        // A lengthless candidate is accepted only when its transaction ID matches
        // the ID ImageCaptureCore placed in the response container. This prevents
        // datasets beginning with an array count of 1, 2, or 3 from being mistaken
        // for command/data/response containers.
        var dataContainer: Data?
        var dataOffset = 4
        if !responseIsFirst,
           firstProbe.kind == .data,
           firstProbe.offset == 4 || first.uint32(at: 4) == transactionID
        {
            dataContainer = first
            dataOffset = firstProbe.offset
        } else if !responseIsSecond,
                  secondProbe.kind == .data,
                  secondProbe.offset == 4 || second.uint32(at: 4) == transactionID
        {
            dataContainer = second
            dataOffset = secondProbe.offset
        }

        var data = Data()
        var dataMode = USBPTPDataMode.none
        if let dataContainer {
            data = payload(of: dataContainer, headerOffset: dataOffset)
            dataMode = .container
        } else if responseContainer != nil {
            // ImageCaptureCore may strip the inbound data-container header and return only the
            // PTP dataset. Only accept that form when the other value is a valid response.
            if !responseIsFirst, !first.isEmpty {
                data = first
                dataMode = .raw
            } else if !responseIsSecond, !second.isEmpty {
                data = second
                dataMode = .raw
            }
        }

        return USBPTPTransactionResult(
            code: code,
            transactionID: transactionID,
            parameters: parameters,
            data: data,
            dataMode: dataMode
        )
    }

    /// 判断容器类型与头部偏移。标准布局带 4 字节长度前缀，长度字段正好等于整包长度。
    static func probeContainer(_ data: Data) -> (kind: USBPTPContainerKind?, offset: Int) {
        if data.count >= 12, Int(data.uint32(at: 0)) == data.count {
            if let kind = USBPTPContainerKind(rawValue: data.uint16(at: 4)) {
                return (kind, 4)
            }
        }
        if data.count >= 8, let kind = USBPTPContainerKind(rawValue: data.uint16(at: 0)) {
            return (kind, 0)
        }
        return (nil, 4)
    }

    private static func payload(of container: Data, headerOffset: Int) -> Data {
        let start = headerOffset + 8
        guard container.count > start else { return Data() }
        var end = container.count
        if headerOffset == 4 {
            let declared = Int(container.uint32(at: 0))
            if declared > start, declared <= container.count {
                end = declared
            }
        }
        return container.subdata(in: start..<end)
    }

    private static func containerDescription(_ kind: USBPTPContainerKind?) -> String {
        switch kind {
        case .command: return "command"
        case .data: return "data"
        case .response: return "response"
        case nil: return "unknown"
        }
    }

    // MARK: - 内容目录

    func catalogSnapshot() -> USBCameraCatalog { catalog }

    /// 等待系统内容目录就绪并建立快照。快速连接只在 PTP 图库失败后调用。
    @discardableResult
    func loadCatalogSnapshot() async throws -> USBCameraCatalog {
        guard let device = activeDevice, isSessionOpen else {
            throw CameraConnectionError.connectionCancelled
        }
        if !catalogDidComplete, device.contentCatalogPercentCompleted < 100 {
            try await waitForCatalog(device)
        }
        catalog = makeCatalogSnapshot(device)
        log("[usb][session] 内容目录完成 folders=\(catalog.folders.count) objects=\(catalog.objectCount)")
        return catalog
    }

    /// 重新遍历目录树。拍摄新照片后相机目录会变化，因此每次手动刷新都重建快照。
    @discardableResult
    func refreshCatalogSnapshot() -> USBCameraCatalog {
        guard let device = activeDevice, isSessionOpen else { return catalog }
        catalog = makeCatalogSnapshot(device)
        return catalog
    }

    func hasObject(handle: UInt32) -> Bool { filesByHandle[handle] != nil }

    var batteryLevel: Int? {
        guard let device = activeDevice, device.batteryLevelAvailable else { return nil }
        let level = device.batteryLevel
        return (0...100).contains(level) ? level : nil
    }

    private func makeCatalogSnapshot(_ device: ICCameraDevice) -> USBCameraCatalog {
        var files: [UInt32: ICCameraFile] = [:]
        var folders: [USBCameraCatalog.Folder] = []

        func entry(for file: ICCameraFile) -> USBCameraCatalog.Entry? {
            let handle = file.ptpObjectHandle
            guard handle != 0 else { return nil }
            files[handle] = file
            let filename = file.originalFilename ?? file.name ?? ""
            return USBCameraCatalog.Entry(
                handle: handle,
                filename: filename,
                fileSize: UInt64(max(file.fileSize, 0)),
                captureDate: file.creationDate ?? file.fileCreationDate,
                isRAW: file.isRaw || Self.looksLikeRAW(filename),
                isVideo: Self.looksLikeVideo(filename: filename, uti: file.uti)
            )
        }

        func walk(_ items: [ICCameraItem], path: [String], folderHandle: UInt32) {
            var childEntries: [USBCameraCatalog.Entry] = []
            for item in items {
                if let folder = item as? ICCameraFolder {
                    let name = folder.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let childPath = name.isEmpty ? path : path + [name]
                    let handle = folder.ptpObjectHandle == 0 ? UInt32(0xFFFF_FFFF) : folder.ptpObjectHandle
                    walk(folder.contents ?? [], path: childPath, folderHandle: handle)
                } else if let file = item as? ICCameraFile, let value = entry(for: file) {
                    childEntries.append(value)
                }
            }
            guard !childEntries.isEmpty else { return }
            folders.append(
                USBCameraCatalog.Folder(
                    handle: folderHandle,
                    storageID: 1,
                    name: path.last ?? "相机存储卡",
                    path: path.joined(separator: "/"),
                    isSyntheticRoot: path.isEmpty,
                    entries: childEntries
                )
            )
        }

        walk(device.contents ?? [], path: [], folderHandle: UInt32(0xFFFF_FFFF))
        filesByHandle = files
        return USBCameraCatalog(folders: folders)
    }

    // MARK: - 缩略图与下载

    func thumbnailData(forHandle handle: UInt32) async throws -> Data? {
        guard let file = filesByHandle[handle] else { return nil }
        let data = try await file.requestThumbnailData(options: nil)
        return data.isEmpty ? nil : data
    }

    /// 从 USB 读取完整对象字节。分块大小远大于 PTP 轮询，配合系统 USB 通路可跑满线路带宽。
    func readObjectData(
        forHandle handle: UInt32,
        progress: (@MainActor (UInt64, UInt64) -> Void)? = nil
    ) async throws -> Data {
        guard let file = filesByHandle[handle] else {
            throw CameraConnectionError.usbUnavailable(
                "USB 目录中未找到对象 0x\(String(format: "%08X", handle))"
            )
        }

        let total = UInt64(max(file.fileSize, 0))
        var collected = Data()
        if total > 0, total < UInt64(Int.max) {
            collected.reserveCapacity(Int(total))
        }

        let chunkSize: Int64 = 8 * 1024 * 1024
        var offset: Int64 = 0
        while true {
            if Task.isCancelled { throw CancellationError() }
            let remaining = Int64(total) - offset
            let length = remaining > 0 ? min(chunkSize, remaining) : chunkSize
            let chunk = try await file.requestReadData(atOffset: off_t(offset), length: off_t(length))
            if chunk.isEmpty { break }
            collected.append(chunk)
            offset += Int64(chunk.count)
            progress?(UInt64(collected.count), max(total, UInt64(collected.count)))
            if total > 0, UInt64(collected.count) >= total { break }
            if Int64(chunk.count) < length { break }
        }
        return collected
    }

    // MARK: - 辅助

    private func refreshStatusMessage() {
        if cameras.isEmpty {
            statusMessage = isBrowsing ? "正在等待 USB 相机接入" : "已停止 USB 检测"
        } else {
            statusMessage = "已发现 \(cameras.count) 台 USB 相机"
        }
    }

    private func log(_ message: String) {
        logHandler?(message)
    }

    private static func authorizationDescription(_ status: ICAuthorizationStatus) -> String {
        if status == .authorized { return "authorized" }
        if status == .denied { return "denied" }
        if status == .restricted { return "restricted" }
        if status == .notDetermined { return "notDetermined" }
        return "unknown(\(status.rawValue))"
    }

    private static func deviceDiagnosticDescription(_ device: ICDevice) -> String {
        let capabilities = device.capabilities.map { String(describing: $0) }.joined(separator: ",")
        return "device class=\(String(describing: Swift.type(of: device))) " +
            "name=\(device.name ?? "--") productKind=\(device.productKind ?? "--") " +
            "transport=\(device.transportType ?? "--") typeRaw=\(device.type.rawValue) " +
            "vid=0x\(String(format: "%04X", UInt32(bitPattern: device.usbVendorID))) " +
            "pid=0x\(String(format: "%04X", UInt32(bitPattern: device.usbProductID))) " +
            "location=0x\(String(format: "%08X", UInt32(bitPattern: device.usbLocationID))) " +
            "uuid=\(device.uuidString ?? "--") hasSession=\(device.hasOpenSession) " +
            "capabilities=[\(capabilities)]"
    }

    static func identifier(for device: ICDevice) -> String {
        if let uuid = device.uuidString, !uuid.isEmpty { return uuid }
        return "usb:\(device.usbLocationID)"
    }

    private static func makeDescriptor(_ device: ICCameraDevice) -> USBCameraDescriptor {
        USBCameraDescriptor(
            id: identifier(for: device),
            name: device.name ?? "",
            model: device.productKind ?? device.name ?? "",
            serialNumber: "",
            vendorID: device.usbVendorID,
            productID: device.usbProductID,
            locationID: device.usbLocationID
        )
    }

    private static let rawExtensions: Set<String> = [
        "NEF", "NRW", "DNG", "CR2", "CR3", "ARW", "RAF", "ORF", "RW2", "RWL", "SRW", "PEF", "3FR", "X3F"
    ]

    private static let videoExtensions: Set<String> = [
        "MOV", "MP4", "M4V", "AVI", "MPEG", "MPG", "MTS", "MXF"
    ]

    private static func fileExtension(_ filename: String) -> String {
        guard let dot = filename.lastIndex(of: ".") else { return "" }
        return String(filename[filename.index(after: dot)...]).uppercased()
    }

    static func looksLikeRAW(_ filename: String) -> Bool {
        rawExtensions.contains(fileExtension(filename))
    }

    static func looksLikeVideo(filename: String, uti: String?) -> Bool {
        if let uti, !uti.isEmpty {
            if uti.hasPrefix("public.movie")
                || uti.hasPrefix("public.mpeg")
                || uti.hasPrefix("public.audiovisual")
                || uti.hasPrefix("com.apple.quicktime")
            {
                return true
            }
        }
        return videoExtensions.contains(fileExtension(filename))
    }

    /// ImageCaptureCore 的回调可能来自任意队列，统一转发到主线程处理。
    func forwardDeviceAdded(_ device: ICDevice, source: String, moreComing: Bool) {
        log(
            "[usb][discovery] didAdd source=\(source) moreComing=\(moreComing) " +
                Self.deviceDiagnosticDescription(device)
        )
        guard let camera = device as? ICCameraDevice else {
            log("[usb][discovery] 忽略非 ICCameraDevice class=\(String(describing: Swift.type(of: device)))")
            return
        }
        register(camera)
    }

    func forwardDeviceRemoved(_ device: ICDevice) {
        unregister(device)
    }

    func forwardCatalogCompleted() {
        catalogDidComplete = true
        catalogProgress = 1
        log("[usb][session] 收到内容目录枚举完成回调")
    }

    func forwardSessionClosed(device: ICDevice, reason: String) {
        handleSessionClosed(device: device, reason: reason)
    }

    func forwardLog(_ message: String) {
        log("[usb] \(message)")
    }
}

/// ICDeviceBrowser / ICDevice / ICCameraDevice 的 Objective-C 回调代理。
///
/// 这些回调不保证在主线程，代理本身保持 nonisolated，只把事件转发回主线程上的 link。
private final class USBCameraProxy: NSObject, ICDeviceBrowserDelegate, ICDeviceDelegate, ICCameraDeviceDelegate {
    weak var link: USBCameraLink?

    init(link: USBCameraLink) {
        self.link = link
    }

    // MARK: ICDeviceBrowserDelegate

    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        Task { @MainActor [weak link] in
            link?.forwardDeviceAdded(device, source: "callback", moreComing: moreComing)
        }
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        Task { @MainActor [weak link] in
            link?.forwardDeviceRemoved(device)
        }
    }

    // MARK: ICDeviceDelegate

    func didRemove(_ device: ICDevice) {
        Task { @MainActor [weak link] in
            link?.forwardDeviceRemoved(device)
        }
    }

    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        Task { @MainActor [weak link] in
            if let error {
                link?.forwardLog(
                    "[session] 打开会话回调 error=\(String(reflecting: error)) " +
                        "description=\(error.localizedDescription)"
                )
            } else {
                link?.forwardLog("[session] 打开会话回调成功 hasOpenSession=\(device.hasOpenSession)")
            }
        }
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
        let reason = error.map { "USB 会话已关闭：\($0.localizedDescription)" } ?? "USB 会话已关闭"
        Task { @MainActor [weak link] in
            link?.forwardSessionClosed(device: device, reason: reason)
        }
    }

    func deviceDidBecomeReady(_ device: ICDevice) {
        Task { @MainActor [weak link] in
            link?.forwardLog("[session] USB 设备已就绪 hasOpenSession=\(device.hasOpenSession)")
        }
    }

    func device(_ device: ICDevice, didEncounterError error: Error?) {
        Task { @MainActor [weak link] in
            link?.forwardLog(
                "[session] 设备错误 error=\(error.map { String(reflecting: $0) } ?? "nil")"
            )
        }
    }

    // MARK: ICCameraDeviceDelegate

    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}

    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}

    func cameraDevice(
        _ camera: ICCameraDevice,
        didReceiveThumbnail thumbnail: CGImage?,
        for item: ICCameraItem,
        error: Error?
    ) {}

    func cameraDevice(
        _ camera: ICCameraDevice,
        didReceiveMetadata metadata: [AnyHashable: Any]?,
        for item: ICCameraItem,
        error: Error?
    ) {}

    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}

    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}

    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}

    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}

    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}

    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        Task { @MainActor [weak link] in
            link?.forwardCatalogCompleted()
        }
    }

    func cameraDevice(_ camera: ICCameraDevice, didCompleteDeleteFilesWithError error: Error?) {
        guard let error else { return }
        Task { @MainActor [weak link] in
            link?.forwardLog("删除对象失败：\(error.localizedDescription)")
        }
    }
}

/// 把上层发出的 PTP/IP 报文翻译成 USB 上的 PTP 容器，再把结果还原成 PTP/IP 报文。
///
/// 事务号、数据分片、响应参数都沿用调用方（CameraConnectionService.operation）的逻辑，
/// 保证 Wi-Fi 与 USB 两条链路的行为完全一致。
@MainActor
final class USBPTPChannel: PTPChannel {
    private struct PendingOperation {
        let code: UInt16
        let transactionID: UInt32
        let dataPhaseInfo: UInt32
        let parameters: [UInt32]
        var expectedDataLength: UInt64?
        var dataPayload: Data
    }

    private let link: USBCameraLink
    private var pending: PendingOperation?
    private var queuedPackets: [PTPIPPacket] = []

    init(link: USBCameraLink) {
        self.link = link
    }

    var isReady: Bool { link.isSessionOpen }

    var linkName: String { "USB PTP" }

    func send(packet: Data) async throws {
        guard packet.count >= 8 else { throw CameraConnectionError.malformedPacket }
        let type = packet.uint32(at: 4)
        let payload = Data(packet.dropFirst(8))

        switch PTPIPPacketType(rawValue: type) {
        case .operationRequest:
            guard payload.count >= 10 else { throw CameraConnectionError.malformedPacket }
            var parameters: [UInt32] = []
            var cursor = 10
            while cursor + 4 <= payload.count {
                parameters.append(payload.uint32(at: cursor))
                cursor += 4
            }
            pending = PendingOperation(
                code: payload.uint16(at: 4),
                transactionID: payload.uint32(at: 6),
                dataPhaseInfo: payload.uint32(at: 0),
                parameters: parameters,
                expectedDataLength: nil,
                dataPayload: Data()
            )
            queuedPackets.removeAll(keepingCapacity: true)

        case .startData:
            guard var operation = pending,
                  operation.dataPhaseInfo == 2,
                  payload.count >= 12,
                  payload.uint32(at: 0) == operation.transactionID
            else {
                throw CameraConnectionError.unexpectedPacket
            }
            operation.expectedDataLength = payload.uint64(at: 4)
            pending = operation

        case .data, .endData:
            guard var operation = pending,
                  operation.dataPhaseInfo == 2,
                  operation.expectedDataLength != nil,
                  payload.count >= 4,
                  payload.uint32(at: 0) == operation.transactionID
            else {
                throw CameraConnectionError.unexpectedPacket
            }
            if payload.count > 4 {
                operation.dataPayload.append(Data(payload.dropFirst(4)))
            }
            pending = operation

        case .cancelTransaction:
            pending = nil
            queuedPackets.removeAll(keepingCapacity: true)

        default:
            break
        }
    }

    func receivePacket() async throws -> PTPIPPacket {
        if !queuedPackets.isEmpty {
            return queuedPackets.removeFirst()
        }
        try await executePending()
        guard !queuedPackets.isEmpty else {
            throw CameraConnectionError.unexpectedPacket
        }
        return queuedPackets.removeFirst()
    }

    func close() {
        pending = nil
        queuedPackets.removeAll(keepingCapacity: true)
    }

    private func executePending() async throws {
        guard let operation = pending else {
            throw CameraConnectionError.unexpectedPacket
        }
        pending = nil

        let isDataOut = operation.dataPhaseInfo == 2
        if isDataOut {
            guard let expectedDataLength = operation.expectedDataLength,
                  UInt64(operation.dataPayload.count) == expectedDataLength
            else {
                throw CameraConnectionError.malformedPacket
            }
        }
        let result = try await link.performTransaction(
            code: operation.code,
            transactionID: operation.transactionID,
            parameters: operation.parameters,
            outgoingData: isDataOut ? operation.dataPayload : nil
        )

        if !isDataOut, !result.data.isEmpty {
            queuedPackets.append(
                PTPIPPacket(
                    type: PTPIPPacketType.startData.rawValue,
                    payload: uint32Data(operation.transactionID)
                        + uint32Data(UInt32(result.data.count))
                        + uint32Data(0)
                )
            )
            let chunkSize = 64 * 1024
            var offset = 0
            while offset < result.data.count {
                let end = min(offset + chunkSize, result.data.count)
                let isLast = end == result.data.count
                let chunk = result.data.subdata(in: offset..<end)
                queuedPackets.append(
                    PTPIPPacket(
                        type: isLast
                            ? PTPIPPacketType.endData.rawValue
                            : PTPIPPacketType.data.rawValue,
                        payload: uint32Data(operation.transactionID) + chunk
                    )
                )
                offset = end
            }
        }

        var responsePayload = uint16Data(result.code) + uint32Data(operation.transactionID)
        for parameter in result.parameters {
            responsePayload.append(uint32Data(parameter))
        }
        queuedPackets.append(
            PTPIPPacket(type: PTPIPPacketType.operationResponse.rawValue, payload: responsePayload)
        )
    }
}
