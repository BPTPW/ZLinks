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
    private var isClosingSession = false
    private var framing: USBPTPFraming = .standard

    // MARK: - 设备发现

    func startDiscovery() {
        guard !browser.isBrowsing else {
            isBrowsing = true
            return
        }
        browser.delegate = proxy
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(
            rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue
        )
        browser.start()
        isBrowsing = true
        refreshStatusMessage()
        for device in browser.devices ?? [] {
            if let camera = device as? ICCameraDevice {
                register(camera)
            }
        }
    }

    func stopDiscovery() {
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
        refreshStatusMessage()
    }

    func unregister(_ device: ICDevice) {
        let identifier = Self.identifier(for: device)
        devicesByID[identifier] = nil
        cameras.removeAll { $0.id == identifier }
        refreshStatusMessage()
        guard connectedDeviceID == identifier else { return }
        let title = connectedDeviceTitle ?? "USB 相机"
        resetSession(reason: "\(title) 的 USB 连接已断开")
    }

    // MARK: - 会话

    /// 打开 USB 会话并准备好两条数据通道。失败时抛出可直接展示给用户的错误。
    func open(_ descriptor: USBCameraDescriptor) async throws {
        closeSession()
        guard let device = devicesByID[descriptor.id] else {
            throw CameraConnectionError.usbUnavailable("未检测到该 USB 相机，请重新插拔数据线后重试")
        }

        activeDevice = device
        connectedDeviceID = descriptor.id
        connectedDeviceTitle = descriptor.title
        device.delegate = proxy
        log("[usb] 打开会话 device=\(descriptor.title) \(descriptor.subtitle)")

        let authorization = await browser.requestControlAuthorization()
        log("[usb] 控制授权 status=\(authorization.rawValue)")

        if !device.hasOpenSession {
            device.requestOpenSession()
        }
        try await waitForSession(device)
        isSessionOpen = true
        log("[usb] 会话已建立 hasOpenSession=\(device.hasOpenSession)")

        catalogDidComplete = false
        await waitForCatalog(device)
        catalog = makeCatalogSnapshot(device)
        log("[usb] 内容目录完成 folders=\(catalog.folders.count) objects=\(catalog.objectCount)")

        do {
            try await negotiateFraming(device)
            isPTPReady = true
        } catch {
            isPTPReady = false
            log("[usb] PTP 直通不可用：\(error.localizedDescription)")
        }
    }

    func closeSession() {
        guard let device = activeDevice else {
            resetSessionState()
            return
        }
        isClosingSession = true
        if device.hasOpenSession {
            device.requestCloseSession()
        }
        device.delegate = nil
        isClosingSession = false
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

    private func handleSessionClosed(reason: String) {
        guard !isClosingSession else { return }
        guard connectedDeviceID != nil else { return }
        resetSession(reason: reason)
    }

    private func waitForSession(_ device: ICCameraDevice) async throws {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if device.hasOpenSession { return }
            if Task.isCancelled { throw CameraConnectionError.connectionCancelled }
            try? await Task.sleep(for: .milliseconds(120))
        }
        throw CameraConnectionError.usbUnavailable("相机未响应 USB 会话请求，请重新插拔数据线后重试")
    }

    private func waitForCatalog(_ device: ICCameraDevice) async {
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            if catalogDidComplete { break }
            let progress = Double(max(0, min(device.contentCatalogPercentCompleted, 100))) / 100
            if progress != catalogProgress { catalogProgress = progress }
            if progress >= 1 { break }
            if Task.isCancelled { break }
            try? await Task.sleep(for: .milliseconds(150))
        }
        catalogDidComplete = true
        catalogProgress = 1
    }

    // MARK: - PTP 直通

    /// 用极小的 PTP 往返确认容器拼装方式，避免把错误的帧格式带进正式会话。
    private func negotiateFraming(_ device: ICCameraDevice) async throws {
        var failures: [String] = []
        for candidate in [USBPTPFraming.standard, .lengthLess] {
            framing = candidate
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
                    failures.append(
                        "\(candidate.rawValue) GetDeviceInfo 0x\(String(format: "%04X", info.code)) bytes=\(info.data.count)"
                    )
                    continue
                }
                log("[usb] PTP 直通就绪 framing=\(candidate.rawValue) deviceInfoBytes=\(info.data.count)")
                return
            } catch {
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
        let dataContainer = outgoingData.map {
            makeDataContainer(code: code, transactionID: transactionID, payload: $0)
        }
        let (first, second) = try await device.requestSendPTPCommand(command, outData: dataContainer)
        return Self.decodeTransaction(
            first: first,
            second: second,
            fallbackTransactionID: transactionID,
            fallbackCode: PTPResponseCode.ok.rawValue
        )
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

    private func makeDataContainer(code: UInt16, transactionID: UInt32, payload: Data) -> Data {
        var body = Data()
        body.append(uint16Data(USBPTPContainerKind.data.rawValue))
        body.append(uint16Data(code))
        body.append(uint32Data(transactionID))
        body.append(payload)
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

        let firstIsResponse = firstProbe.kind == .response
        let secondIsResponse = secondProbe.kind == .response
        var responseContainer: Data?
        var responseOffset = 4
        if firstIsResponse {
            responseContainer = first
            responseOffset = firstProbe.offset
        } else if secondIsResponse {
            responseContainer = second
            responseOffset = secondProbe.offset
        }

        var dataContainer: Data?
        var dataOffset = 4
        if firstProbe.kind == .data, !firstIsResponse {
            dataContainer = first
            dataOffset = firstProbe.offset
        } else if secondProbe.kind == .data, !secondIsResponse {
            dataContainer = second
            dataOffset = secondProbe.offset
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

        var data = Data()
        if let dataContainer {
            data = payload(of: dataContainer, headerOffset: dataOffset)
        }

        return USBPTPTransactionResult(
            code: code,
            transactionID: transactionID,
            parameters: parameters,
            data: data
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

    // MARK: - 内容目录

    func catalogSnapshot() -> USBCameraCatalog { catalog }

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

    static func identifier(for device: ICDevice) -> String {
        if let uuid = device.uuidString, !uuid.isEmpty { return uuid }
        if let serial = device.serialNumberString, !serial.isEmpty { return "serial:\(serial)" }
        return "usb:\(device.usbLocationID)"
    }

    private static func makeDescriptor(_ device: ICCameraDevice) -> USBCameraDescriptor {
        USBCameraDescriptor(
            id: identifier(for: device),
            name: device.name ?? "",
            model: device.productKind ?? device.name ?? "",
            serialNumber: device.serialNumberString ?? "",
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
    func forwardDeviceAdded(_ device: ICDevice) {
        guard let camera = device as? ICCameraDevice else { return }
        register(camera)
    }

    func forwardDeviceRemoved(_ device: ICDevice) {
        unregister(device)
    }

    func forwardCatalogCompleted() {
        catalogDidComplete = true
        catalogProgress = 1
        log("[usb] 内容目录枚举完成")
    }

    func forwardSessionClosed(reason: String) {
        handleSessionClosed(reason: reason)
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
            link?.forwardDeviceAdded(device)
        }
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        Task { @MainActor [weak link] in
            link?.forwardDeviceRemoved(device)
        }
    }

    func deviceBrowserDidEnumerateLocalDevices(_ browser: ICDeviceBrowser) {
        Task { @MainActor [weak link] in
            link?.forwardLog("已完成本机 USB 设备枚举")
        }
    }

    // MARK: ICDeviceDelegate

    func didRemove(_ device: ICDevice) {
        Task { @MainActor [weak link] in
            link?.forwardDeviceRemoved(device)
        }
    }

    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        guard let error else { return }
        Task { @MainActor [weak link] in
            link?.forwardLog("打开会话返回错误：\(error.localizedDescription)")
        }
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
        let reason = error.map { "USB 会话已关闭：\($0.localizedDescription)" } ?? "USB 会话已关闭"
        Task { @MainActor [weak link] in
            link?.forwardSessionClosed(reason: reason)
        }
    }

    func deviceDidBecomeReady(_ device: ICDevice) {
        Task { @MainActor [weak link] in
            link?.forwardLog("USB 设备已就绪")
        }
    }

    // MARK: ICCameraDeviceDelegate

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
                dataPayload: Data()
            )
            queuedPackets.removeAll(keepingCapacity: true)

        case .startData, .data, .endData:
            guard var operation = pending, payload.count >= 4 else {
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
