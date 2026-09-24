//
//  MyCameraView.swift
//  ZLinks
//

import MapKit
import SwiftUI
import UIKit

struct MyCameraView: View {
    @EnvironmentObject private var camera: CameraConnectionService
    @State private var isConnectionSheetPresented = false
    @State private var isBluetoothGPSPresented = false
    @State private var isShareSheetPresented = false
    @State private var exportedLogURL: URL?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    cameraStatusCard
                    storageInfoCard
                    lensInfoCard
                    bluetoothGPSCard
                    exportLogButton
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
            .navigationTitle("我的相机")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsView(camera: camera)
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.body.weight(.semibold))
                    }
                    .accessibilityLabel("设置")

                    Button {
                        Task { await camera.refreshCameraStatus() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.body.weight(.semibold))
                    }
                    .disabled(camera.state != .connected)
                    .accessibilityLabel("刷新相机状态")
                }
            }
            .sheet(isPresented: $isConnectionSheetPresented) {
                CameraConnectionSheet(camera: camera)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    .presentationCornerRadius(28)
            }
            .sheet(isPresented: $isShareSheetPresented) {
                if let exportedLogURL {
                    ActivityViewController(activityItems: [exportedLogURL])
                        .ignoresSafeArea()
                }
            }
            .fullScreenCover(isPresented: $isBluetoothGPSPresented, onDismiss: {
                camera.closeBluetoothGPSSession()
            }) {
                BluetoothGPSConnectionView(camera: camera)
            }
            .task(id: camera.state) {
                await camera.refreshCameraStatusPeriodically()
            }
        }
    }

    private var exportLogButton: some View {
        Button {
            exportConnectionLog()
        } label: {
            Label("导出连接日志", systemImage: "square.and.arrow.up")
                .font(.headline)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glass)
        .accessibilityIdentifier("exportConnectionLogButton")
    }

    private func exportConnectionLog() {
        let fileName = "ZLinks-连接日志-\(Self.exportFileDateFormatter.string(from: Date())).txt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        let contents = camera.debugLog.isEmpty ? "暂无连接日志\n" : camera.debugLog + "\n"

        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
            exportedLogURL = url
            isShareSheetPresented = true
        } catch {
            // The temporary directory is expected to be writable. If it is not,
            // leave the current screen in place rather than presenting an empty share sheet.
        }
    }

    private static let exportFileDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    private var cameraStatusCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: cameraIcon)
                    .font(.system(size: 24, weight: .semibold))
                    .frame(width: 48, height: 48)
                    .foregroundStyle(statusTint)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14))

                VStack(alignment: .leading, spacing: 5) {
                    Text(cameraTitle)
                        .font(.title2.bold())
                    Text(cameraSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 8) {
                    statusLabel
                    batteryBadge
                }
            }

            if case .connected = camera.state {
                detailRow("连接方式", value: camera.linkKind.title)
                detailRow("相机地址", value: camera.connectedHost ?? "--")
            }
            Divider()

            Button {
                if case .connected = camera.state {
                    camera.disconnect()
                } else {
                    isConnectionSheetPresented = true
                }
            } label: {
                Label(connectionActionTitle, systemImage: connectionActionIcon)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .tint(statusTint)
            .accessibilityIdentifier("cameraConnectionButton")
        }
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.clear)
                .glassEffect(.regular, in: .rect(cornerRadius: 24))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.primary.opacity(0.12), lineWidth: 1)
        }
    }

    private var lensInfoCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("镜头信息")
                    .font(.title3.bold())
                Text(lensIDText)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Text(lensConnectionStatusTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(lensStatusTint)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(lensStatusTint.opacity(0.14), in: Capsule())
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                lensMetricModule(title: "焦距范围", value: focalLengthRangeText)
                lensMetricModule(title: "光圈范围", value: apertureRangeText)
                lensMetricModule(title: "当前焦距", value: currentFocalLengthText)
                lensMetricModule(title: "当前光圈", value: currentApertureText)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.clear)
                .glassEffect(.regular, in: .rect(cornerRadius: 24))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.primary.opacity(0.12), lineWidth: 1)
        }
    }

    private var bluetoothGPSCard: some View {
        Button {
            camera.openBluetoothGPSSession()
            isBluetoothGPSPresented = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "mappin.and.ellipse.circle")
                    .font(.system(size: 27, weight: .semibold))
                    .foregroundStyle(.cyan)
                    .frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 4) {
                    Text("GPS同步")
                        .font(.headline.weight(.semibold))
                    Text("蓝牙配对相机并进行gps同步")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.clear)
                .glassEffect(.regular, in: .rect(cornerRadius: 24))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.primary.opacity(0.12), lineWidth: 1)
        }
    }

    private func lensMetricModule(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(value == "--" ? .secondary : .primary)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
        .background(.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var lensConnectionStatusTitle: String {
        switch camera.state {
        case .disconnected:
            return CameraConnectionService.LensConnectionState.disconnected.title
        case .connecting:
            return "连接中"
        case .failed:
            return "连接失败"
        case .connected:
            return camera.lensInfo.connectionState.title
        }
    }

    private var lensStatusTint: Color {
        switch camera.state {
        case .disconnected:
            return .secondary
        case .connecting:
            return .blue
        case .failed:
            return .red
        case .connected:
            switch camera.lensInfo.connectionState {
            case .connected:
                return .green
            case .noneAttached:
                return .orange
            case .unknown:
                return .secondary
            case .disconnected:
                return .secondary
            }
        }
    }

    private var lensIDText: String {
        guard case .connected = camera.state else {
            return ""
        }
        guard let lensID = camera.lensInfo.lensID else {
            switch camera.lensInfo.connectionState {
            case .noneAttached:
                return ""
            case .unknown:
                return "未知"
            case .connected, .disconnected:
                return ""
            }
        }
        return "ID \(lensID)"
    }

    private var focalLengthRangeText: String {
        guard case .connected = camera.state else { return "--" }
        let min = camera.lensInfo.minFocalLengthMM
        let max = camera.lensInfo.maxFocalLengthMM
        switch (min, max) {
        case let (min?, max?) where abs(min - max) < 0.05:
            return formatLensFocalLength(min)
        case let (min?, max?):
            return "\(formatLensFocalLength(min)) – \(formatLensFocalLength(max))"
        case let (min?, nil):
            return formatLensFocalLength(min)
        case let (nil, max?):
            return formatLensFocalLength(max)
        default:
            return "--"
        }
    }

    private var apertureRangeText: String {
        guard case .connected = camera.state else { return "--" }
        let minF = camera.lensInfo.maxApertureAtMinFocal
        let maxF = camera.lensInfo.maxApertureAtMaxFocal
        switch (minF, maxF) {
        case let (minF?, maxF?) where abs(minF - maxF) < 0.02:
            return formatLensAperture(minF)
        case let (minF?, maxF?):
            return "\(formatLensAperture(minF)) – \(formatLensAperture(maxF))"
        case let (minF?, nil):
            return formatLensAperture(minF)
        case let (nil, maxF?):
            return formatLensAperture(maxF)
        default:
            return "--"
        }
    }

    private var currentFocalLengthText: String {
        guard case .connected = camera.state,
              let value = camera.lensInfo.currentFocalLengthMM
        else {
            return "--"
        }
        return formatLensFocalLength(value)
    }

    private var currentApertureText: String {
        guard case .connected = camera.state,
              let value = camera.lensInfo.currentAperture
        else {
            return "--"
        }
        return formatLensAperture(value)
    }

    private func formatLensFocalLength(_ mm: Double) -> String {
        if abs(mm.rounded() - mm) < 0.05 {
            return String(format: "%.0f mm", mm)
        }
        return String(format: "%.1f mm", mm)
    }

    private func formatLensAperture(_ value: Double) -> String {
        if abs(value.rounded() - value) < 0.05 {
            return String(format: "f/%.0f", value)
        }
        let tenths = (value * 10).rounded() / 10
        if abs(tenths - value) < 0.02 {
            return String(format: "f/%.1f", tenths)
        }
        return String(format: "f/%.2f", value)
    }

    private var batteryBadge: some View {
        HStack(spacing: 6) {
            Text(batteryText)
                .font(.subheadline.monospacedDigit().weight(.semibold))
            Image(systemName: batterySymbol)
                .font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(batteryTint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .accessibilityLabel("电量 \(batteryText)")
    }

    private var storageInfoCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Text("存储空间")
                    .font(.title3.bold())
                Spacer(minLength: 0)
            }

            storageSummary(
                used: totalStorageUsedBytes,
                total: totalStorageBytes,
                free: totalStorageFreeBytes,
                isLow: isTotalStorageLow
            )

            ProgressView(value: totalStorageUsedRatio)
                .tint(isTotalStorageLow ? .red : .blue)
                .scaleEffect(x: 1, y: 1.35, anchor: .center)

            if camera.cameraStatus.storages.isEmpty {
                Text(camera.state == .connected ? "未检测到存储卡" : "连接相机后显示存储信息")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 72, alignment: .center)
                    .background(.primary.opacity(0.02), in: RoundedRectangle(cornerRadius: 16))
            } else {
                ForEach(camera.cameraStatus.storages) { storage in
                    storageCard(storage)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.clear)
                .glassEffect(.regular, in: .rect(cornerRadius: 24))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.primary.opacity(0.12), lineWidth: 1)
        }
    }

    private func storageCard(_ storage: CameraConnectionService.StorageInfo) -> some View {
        let used = usedBytes(total: storage.totalBytes, free: storage.freeBytes)
        let isLow = isStorageLow(total: storage.totalBytes, free: storage.freeBytes)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "sdcard.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.blue)
                Text(storage.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
            }

            ProgressView(value: storageUsedRatio(total: storage.totalBytes, free: storage.freeBytes))
                .tint(isLow ? .red : .blue)
                .scaleEffect(x: 1, y: 1.35, anchor: .center)

            storageUsageLine(used: used, total: storage.totalBytes, free: storage.freeBytes, isLow: isLow)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.primary.opacity(0.02), in: RoundedRectangle(cornerRadius: 16))
    }

    private func storageSummary(used: UInt64?, total: UInt64?, free: UInt64?, isLow: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(used.map(formatBytes) ?? "--")
                .font(.title2.bold())
                .fontDesign(.rounded)
                .foregroundStyle(isLow ? .red : .primary)
            Text("/ \(total.map(formatBytes) ?? "--") · 可用 \(free.map(formatBytes) ?? "--")")
                .font(.subheadline)
                .fontDesign(.rounded)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .accessibilityElement(children: .combine)
    }

    private func storageUsageLine(used: UInt64, total: UInt64, free: UInt64, isLow: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(formatBytes(used))
                .font(.subheadline.weight(.semibold))
                .fontDesign(.rounded)
                .foregroundStyle(isLow ? .red : .primary)
            Text("/ \(formatBytes(total)) · 可用 \(formatBytes(free))")
                .font(.caption)
                .fontDesign(.rounded)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Spacer(minLength: 0)
        }
    }

    private var statusLabel: some View {
        Text(connectionStatusTitle)
            .font(.caption.weight(.semibold))
            .foregroundStyle(statusTint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(statusTint.opacity(0.14), in: Capsule())
    }

    private var cameraTitle: String {
        camera.cameraInfo?.model ?? "未连接相机"
    }

    private var cameraSubtitle: String {
        if camera.isReconnecting {
            return "正在恢复与相机的连接"
        }
        if let cameraInfo = camera.cameraInfo {
            return "\(cameraInfo.manufacturer) · \(cameraInfo.model)"
        }
        return "Nikon · 等待连接"
    }

    private var cameraIcon: String {
        switch camera.state {
        case .connected:
            return "camera.fill"
        case .connecting:
            return "antenna.radiowaves.left.and.right"
        case .disconnected, .failed:
            return "camera"
        }
    }

    private var statusTint: Color {
        switch camera.state {
        case .connected:
            return .green
        case .connecting:
            return .blue
        case .disconnected:
            return .primary
        case .failed:
            return .red
        }
    }

    private var connectionStatusTitle: String {
        switch camera.state {
        case .connected:
            return "已连接"
        case .connecting:
            return camera.isReconnecting ? "正在重连" : "连接中"
        case .disconnected:
            return "未连接"
        case .failed:
            return "连接失败"
        }
    }

    private var connectionActionTitle: String {
        switch camera.state {
        case .connected:
            return "断开相机"
        case .connecting:
            return camera.isReconnecting ? "正在重连" : "正在连接"
        case .disconnected, .failed:
            return "连接相机"
        }
    }

    private var connectionActionIcon: String {
        switch camera.state {
        case .connected:
            return "xmark.circle"
        case .connecting:
            return "arrow.triangle.2.circlepath"
        case .disconnected, .failed:
            return "wifi"
        }
    }

    private var batteryText: String {
        guard case .connected = camera.state,
              let level = camera.cameraStatus.batteryLevel
        else {
            return "--%"
        }
        return "\(level)%"
    }

    private var batteryTint: Color {
        guard case .connected = camera.state,
              let level = camera.cameraStatus.batteryLevel
        else {
            return .secondary
        }
        switch level {
        case 0..<10:
            return .red
        case 10..<20:
            return .orange
        default:
            return .green
        }
    }

    private var batterySymbol: String {
        guard case .connected = camera.state,
              let level = camera.cameraStatus.batteryLevel
        else {
            return "battery.0percent"
        }
        switch level {
        case 76...:
            return "battery.100percent"
        case 51...75:
            return "battery.75percent"
        case 26...50:
            return "battery.50percent"
        case 1...25:
            return "battery.25percent"
        default:
            return "battery.0percent"
        }
    }

    private var totalStorageBytes: UInt64? {
        camera.cameraStatus.storageTotalBytes
    }

    private var totalStorageFreeBytes: UInt64? {
        camera.cameraStatus.storageFreeBytes
    }

    private var totalStorageUsedBytes: UInt64? {
        guard let total = totalStorageBytes, let free = totalStorageFreeBytes else { return nil }
        return usedBytes(total: total, free: free)
    }

    private var totalStorageUsedRatio: Double {
        guard let total = totalStorageBytes, let free = totalStorageFreeBytes else { return 0 }
        return storageUsedRatio(total: total, free: free)
    }

    private var isTotalStorageLow: Bool {
        guard let total = totalStorageBytes, let free = totalStorageFreeBytes else { return false }
        return isStorageLow(total: total, free: free)
    }

    private func usedBytes(total: UInt64, free: UInt64) -> UInt64 {
        total > free ? total - free : 0
    }

    private func storageUsedRatio(total: UInt64, free: UInt64) -> Double {
        guard total > 0 else { return 0 }
        return min(max(Double(usedBytes(total: total, free: free)) / Double(total), 0), 1)
    }

    private func isStorageLow(total: UInt64, free: UInt64) -> Bool {
        guard total > 0 else { return false }
        return Double(free) / Double(total) < 0.1
    }

    private func detailRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.subheadline)
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary)
    }
}

struct CameraConnectionSheet: View {
    enum ConnectionMode: String, CaseIterable, Identifiable {
        case accessPoint = "AP 模式"
        case station = "STA 模式"
        case usb = "USB 有线"

        var id: Self { self }
    }

    @ObservedObject var camera: CameraConnectionService
    @Environment(\.dismiss) private var dismiss
    @StateObject private var discovery = CameraDiscoveryService()
    @AppStorage(CameraConnectionService.autoConnectOnLaunchKey) private var autoConnectOnLaunch = false
    @AppStorage(CameraConnectionService.usbFastConnectKey) private var usbFastConnect = true
    @State private var selectedMode: ConnectionMode = .accessPoint
    @State private var isConnecting = false
    @State private var isAdvancedOptionsExpanded = false
    @State private var manualHost = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("连接模式", selection: $selectedMode) {
                    ForEach(ConnectionMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)
                .padding(.top, 12)

                ScrollView {
                    VStack(alignment: .center, spacing: 24) {
                        modeGuide
                        if selectedMode == .accessPoint {
                            cameraWiFiForm
                        }
                        if selectedMode == .usb {
                            usbCameras
                        } else {
                            discoveredCameras
                            advancedOptions
                        }

                        if isConnecting {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text(selectedMode == .usb ? camera.usbLink.statusMessage : "正在连接相机…")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if case let .failed(message) = camera.state {
                            Label(message, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                                .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                        }
                    }
                    .padding(20)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("连接相机")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
            .onChange(of: camera.state) { _, state in
                if case .connected = state {
                    dismiss()
                }
            }
            .onChange(of: selectedMode) { _, mode in
                if mode == .usb {
                    discovery.stop()
                    camera.usbLink.startDiscovery()
                } else {
                    camera.usbLink.stopDiscovery()
                    discovery.start()
                }
            }
            .onDisappear {
                discovery.stop()
                camera.usbLink.stopDiscovery()
            }
            .onAppear {
                if selectedMode == .usb {
                    camera.usbLink.startDiscovery()
                } else {
                    discovery.start()
                }
            }
        }
    }

    @ViewBuilder
    private var modeGuide: some View {
        switch selectedMode {
        case .accessPoint:
            GuidePanel(
                title: "连接相机 WI-FI 网络",
                symbol: "wifi",
                steps: [
                    "在相机网络菜单中开启 Wi-Fi。",
                    "在设置中手动连接相机 Wi-Fi。",
                    "在连接完成后点击扫描对网络中的相机设备进行扫描。"
                ],
                note: "若无法搜索到相机，可以在高级选项中输入相机 IP 地址直接连接。扫描使用 PTP/IP 默认端口 15740。"
            )
        case .station:
            GuidePanel(
                title: "相机 STA 模式连接网络",
                symbol: "network",
                steps: [
                    "在相机网络菜单中选择连接至已有 Wi-Fi 或手机热点。",
                    "若连接的是已有 WI-FI，则让 iPhone 加入相同的局域网。",
                    "点击扫描将自动发现局域网中的相机设备"
                ],
                note: "若无法搜索到相机，可以在高级选项中输入相机 IP 地址直接连接。扫描使用 PTP/IP 默认端口 15740。"
            )
        case .usb:
            GuidePanel(
                title: "USB 有线连接",
                symbol: "cable.connector.video",
                steps: [
                    "使用 USB 数据线连接相机与手机连接。",
                    "在相机 USB 中保证 MTP/PTP 功能打开。",
                    "保持相机开机，在下方列表点击识别到的相机即可连接。"
                ],
                note: "若无法搜索到相机，请检查相机是否开机、线材是否为原装，或重启软件后再试。"
            )
        }
    }

    private var cameraWiFiForm: some View {
        Button {
            openWiFiSettings()
        } label: {
            Label("打开 WI-FI 设置", systemImage: "wifi")
                .font(.headline)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .accessibilityIdentifier("openWiFiSettingsButton")
    }

    private func openWiFiSettings() {
        guard let url = URL(string: "App-Prefs:root=WIFI") else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    private var discoveredCameras: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("发现相机")
                    .font(.headline).fontWeight(.semibold)
                Spacer()
                Button {
                    discovery.start()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .frame(width: 42, height: 42)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("重新扫描本地相机")
            }

            if discovery.cameras.isEmpty {
                HStack(spacing: 10) {
                    if discovery.isSearching {
                        ProgressView()
                    }
                    Text(discovery.statusMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
            } else {
                ForEach(discovery.cameras) { discoveredCamera in
                    Button {
                        isConnecting = true
                        Task {
                            await camera.connect(endpoint: discoveredCamera.endpoint, displayHost: discoveredCamera.name)
                            isConnecting = false
                        }
                    } label: {
                        HStack {
                            Label(discoveredCamera.name, systemImage: "camera")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                    }
                    .buttonStyle(.glass)
                    .disabled(isConnecting)
                }
            }

            Toggle(isOn: $autoConnectOnLaunch) {
                Text("应用启动时恢复连接")
                    .font(.subheadline.weight(.medium))
            }
            .tint(.blue)
            .padding(.vertical, 8)
        }
    }

    private var usbCameras: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("USB 相机")
                    .font(.headline).fontWeight(.semibold)
                Spacer()
                Button {
                    camera.usbLink.startDiscovery()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .frame(width: 42, height: 42)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("重新扫描 USB 相机")
            }

            if camera.usbLink.cameras.isEmpty {
                HStack(spacing: 10) {
                    if camera.usbLink.isBrowsing {
                        ProgressView()
                    }
                    Text(camera.usbLink.statusMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
            } else {
                ForEach(camera.usbLink.cameras) { usbCamera in
                    Button {
                        isConnecting = true
                        Task { @MainActor in
                            await camera.connectUSBCamera(usbCamera, fastConnect: usbFastConnect)
                            isConnecting = false
                        }
                    } label: {
                        HStack(alignment: .center, spacing: 12) {
                            Image(systemName: "cable.connector")
                                .font(.body.weight(.semibold))
                            Text(usbCamera.title)
                                .font(.subheadline.weight(.semibold))
                            Text(usbCamera.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                    }
                    .buttonStyle(.glass)
                    .disabled(isConnecting)
                    .accessibilityIdentifier("usbCameraButton")
                }
            }

            Toggle(isOn: $usbFastConnect) {
                Text("快速连接")
                    .font(.subheadline.weight(.medium))
            }
            .tint(.blue)
            .padding(.vertical, 8)
        }
    }

    private var advancedOptions: some View {
        DisclosureGroup(isExpanded: $isAdvancedOptionsExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                Text("适用于自动扫描未发现相机，或已知相机 IP 的情况。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                TextField("输入相机IP", text: $manualHost)
                    .keyboardType(.decimalPad)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .glassEffect(.regular.interactive(), in: .capsule)

                HStack {
                    Spacer()
                    Button {
                        let host = manualHost.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !host.isEmpty else { return }
                        isConnecting = true
                        Task {
                            await camera.connect(host: host)
                            isConnecting = false
                        }
                    } label: {
                        HStack {
                            if isConnecting {
                                ProgressView()
                            }
                            Text("连接")
                            Image(systemName: "link")
                        }
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.blue)
                    .disabled(isConnecting || manualHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(.top, 8)
        } label: {
            Label("高级选项", systemImage: "slider.horizontal.3")
                .font(.headline)
        }
        .tint(.primary)
    }
}

private struct BluetoothGPSConnectionView: View {
    @ObservedObject var camera: CameraConnectionService
    @Environment(\.dismiss) private var dismiss
    @AppStorage(MapOffsetCorrectionMode.preferenceKey)
    private var mapOffsetCorrectionMode = MapOffsetCorrectionMode.automatic
    @State private var mapPosition: MapCameraPosition = .automatic

    private var gps: NikonBluetoothGPSService { camera.bluetoothGPS }

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: "mappin.and.ellipse.circle.fill")
                        .font(.system(size: 62, weight: .medium))
                        .foregroundStyle(statusTint)
                        .padding(.top, 18)

                    Text("GPS 同步")
                        .font(.largeTitle.bold())

                    Text(gps.state.title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(statusTint)

                    Text(gps.connectionStepDescription)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 520)
                        .padding(14)
                        .background(statusTint.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                    if case .failed = gps.state {
                        Button {
                            gps.retry()
                        } label: {
                            Label("重试", systemImage: "arrow.clockwise")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .tint(.blue)
                    }

                    if let location = gps.lastLocation {
                        locationSummary(location)
                    }

                    Map(position: $mapPosition) {
                        if let location = gps.lastLocation {
                            Marker("当前位置", coordinate: mapCoordinate(for: location))
                                .tint(.cyan)
                        }
                    }
                    .frame(minHeight: 260, maxHeight: 340)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(.primary.opacity(0.12), lineWidth: 1)
                    }

                    HStack(spacing: 12) {
                        Label("同步策略", systemImage: "timer")
                            .font(.headline)
                        Spacer(minLength: 8)
                        Picker("同步策略", selection: Binding(
                            get: { gps.syncStrategy },
                            set: { gps.syncStrategy = $0 }
                        )) {
                            ForEach(NikonBluetoothGPSService.SyncStrategy.allCases) { strategy in
                                Text(strategy.title).tag(strategy)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(.primary)
                    }
                    .padding(.horizontal, 4)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 28)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button(role: .destructive) {
                dismiss()
            } label: {
                Text("停止 GPS 同步")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.glassProminent)
            .tint(.red)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .interactiveDismissDisabled()
        .onAppear { recenterMap() }
        .onChange(of: gps.lastLocation?.timestamp) { _, _ in recenterMap() }
        .onChange(of: mapOffsetCorrectionMode) { _, _ in recenterMap() }
    }

    private func locationSummary(_ location: CLLocation) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(String(format: "纬度 %.6f， 经度 %.6f", location.coordinate.latitude, location.coordinate.longitude))
                .font(.headline.monospacedDigit())
            Text(String(format: "误差 %.1f 米", max(location.horizontalAccuracy, 0)))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let date = gps.lastSyncDate {
                Text("上次同步 \(Self.dateFormatter.string(from: date))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func recenterMap() {
        guard let location = gps.lastLocation else { return }
        mapPosition = .region(MKCoordinateRegion(
            center: mapCoordinate(for: location),
            span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
        ))
    }

    private func mapCoordinate(for location: CLLocation) -> CLLocationCoordinate2D {
        MapCoordinateCorrection.coordinateForMap(
            location.coordinate,
            mode: mapOffsetCorrectionMode
        )
    }

    private var statusTint: Color {
        switch gps.state {
        case .ready: return .green
        case .failed: return .red
        case .unavailable: return .orange
        case .idle: return .secondary
        case .scanning, .connecting, .pairing, .reconnecting: return .blue
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

private struct ActivityViewController: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct GuidePanel: View {
    let title: String
    let symbol: String
    let steps: [String]
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(title, systemImage: symbol)
                .font(.title3.bold())

            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 12) {
                        Text("\(index + 1)")
                            .font(.caption.bold())
                            .frame(width: 22, height: 22)
                            .foregroundStyle(.blue)
                            .background(.blue.opacity(0.14), in: Circle())
                        Text(step)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Label(note, systemImage: "info.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }
}

#Preview {
    MyCameraView()
}
