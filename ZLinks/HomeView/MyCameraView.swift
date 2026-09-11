//
//  MyCameraView.swift
//  ZLinks
//

import SwiftUI

struct MyCameraView: View {
    @EnvironmentObject private var camera: CameraConnectionService
    @State private var isConnectionSheetPresented = false
    @State private var isDebugLogPresented = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    cameraStatusCard
                    lensInfoCard
                    if camera.state != .connected {
                        preparationSection
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
            .navigationTitle("我的相机")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        isDebugLogPresented = true
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.body.weight(.semibold))
                    }
                    .accessibilityLabel("连接日志")
                    
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
            .fullScreenCover(isPresented: $isDebugLogPresented) {
                CameraDebugLogView(camera: camera)
            }
        }
    }

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
                storageSection

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
                    .font(.headline)
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
              let value = camera.lensInfo.currentFocalLengthMM else {
            return "--"
        }
        return formatLensFocalLength(value)
    }

    private var currentApertureText: String {
        guard case .connected = camera.state,
              let value = camera.lensInfo.currentAperture else {
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

    private var storageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "externaldrive.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.blue)
                Text("存储空间")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                if let storageName = camera.cameraStatus.storageName, !storageName.isEmpty {
                    Text(storageName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            ProgressView(value: storageUsedRatio)
                .tint(.blue)
                .scaleEffect(x: 1, y: 1.35, anchor: .center)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(storageUsageText)
                    .font(.subheadline.monospacedDigit().weight(.medium))
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.primary.opacity(0.02), in: RoundedRectangle(cornerRadius: 16))
    }

    private var preparationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("连接准备")
                .font(.headline)
            Text("请先让 iPhone 与相机处于同一个 Wi-Fi 网络，或加入相机创建的 Wi-Fi 网络。连接后会读取相机品牌、型号、镜头信息和存储状态。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
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
              let level = camera.cameraStatus.batteryLevel else {
            return "--%"
        }
        return "\(level)%"
    }

    private var batteryTint: Color {
        guard case .connected = camera.state,
              let level = camera.cameraStatus.batteryLevel else {
            return .secondary
        }
        switch level {
        case 0..<20:
            return .red
        case 20..<40:
            return .orange
        default:
            return .green
        }
    }

    private var batterySymbol: String {
        guard case .connected = camera.state,
              let level = camera.cameraStatus.batteryLevel else {
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

    private var storageUsedRatio: Double {
        guard let free = camera.cameraStatus.storageFreeBytes,
              let total = camera.cameraStatus.storageTotalBytes,
              total > 0 else {
            return 0
        }
        let used = total > free ? total - free : 0
        return min(max(Double(used) / Double(total), 0), 1)
    }

    private var storageUsageText: String {
        guard let free = camera.cameraStatus.storageFreeBytes,
              let total = camera.cameraStatus.storageTotalBytes else {
            return "-- / --"
        }
        let used = total > free ? total - free : 0
        return "\(formatBytes(used)) / \(formatBytes(total))"
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
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

private struct CameraConnectionSheet: View {
    enum ConnectionMode: String, CaseIterable, Identifiable {
        case accessPoint = "AP 模式"
        case station = "STA 模式"

        var id: Self { self }
    }

    @ObservedObject var camera: CameraConnectionService
    @Environment(\.dismiss) private var dismiss
    @StateObject private var discovery = CameraDiscoveryService()
    @StateObject private var wifi = CameraWiFiService()
    @State private var selectedMode: ConnectionMode = .accessPoint
    @State private var isConnecting = false
    @AppStorage("camera.wifi.ssid") private var cameraSSID = "NIKON_"
    @AppStorage("camera.wifi.password") private var cameraPassword = ""
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
                    VStack(alignment: .leading, spacing: 24) {
                        modeGuide
                        if selectedMode == .accessPoint {
                            cameraWiFiForm
                        }
                        discoveredCameras
                        advancedOptions

                        if case .failed(let message) = camera.state {
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
            .onChange(of: selectedMode) { _, mode in
                wifi.reset()
                if mode == .station {
                    discovery.start()
                } else {
                    discovery.stop()
                }
            }
            .onChange(of: camera.state) { _, state in
                if case .connected = state {
                    dismiss()
                }
            }
            .onDisappear {
                discovery.stop()
            }
            .onAppear {
                if selectedMode == .station {
                    discovery.start()
                }
            }
        }
    }

    @ViewBuilder
    private var modeGuide: some View {
        if selectedMode == .accessPoint {
            GuidePanel(
                title: "相机创建 Wi-Fi 网络",
                symbol: "wifi",
                steps: [
                    "在相机网络菜单中开启 Wi-Fi 或连接至智能设备。",
                    "在下方输入相机显示的 SSID 和密码，点击加入网络。",
                    "确认系统弹窗后，回到 ZLinks 扫描相机。",
                    "从发现的相机列表中选择设备并读取基础信息。"
                ],
                note: "iOS 公开 API 不允许普通 App 扫描附近所有 SSID，因此不能可靠地自动列出 NIKON_ 网络。加入相机网络时系统会负责确认和路由；蜂窝数据是否并行可用由 iOS 决定。"
            )
        } else {
            GuidePanel(
                title: "相机加入本地网络",
                symbol: "network",
                steps: [
                    "在相机网络菜单中选择连接至已有 Wi-Fi 或手机热点。",
                    "让 iPhone 加入相同的局域网或开启对应个人热点。",
                    "ZLinks 会自动扫描当前 Wi-Fi 子网的 PTP/IP 相机。",
                    "从发现的相机列表中选择设备并读取基础信息。"
                ],
                note: "手机热点模式下，相机需要先成功加入 iPhone 热点。扫描使用 PTP/IP 默认端口 15740。"
            )
        }
    }

    private var cameraWiFiForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("加入相机 Wi-Fi")
                .font(.headline)

            TextField("SSID", text: $cameraSSID)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)

            SecureField("密码（开放网络可留空）", text: $cameraPassword)
                .textFieldStyle(.roundedBorder)

            HStack{
                Spacer()
                Button {
                    Task {
                        await wifi.joinCameraNetwork(
                            ssid: cameraSSID,
                            password: cameraPassword.isEmpty ? nil : cameraPassword
                        )
                        if case .joined = wifi.state {
                            try? await Task.sleep(for: .seconds(1))
                            discovery.start()
                        }
                    }
                } label: {
                    HStack {
                        if case .joining = wifi.state {
                            ProgressView()
                        }
                        Text("加入网络")
                        Image(systemName: "wifi")
                    }
                    .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .disabled(cameraSSID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || wifi.state == .joining)
            }
            

            if case .failed(let message) = wifi.state {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.red)
            } else if case .joined = wifi.state {
                Label("已请求加入网络，正在等待相机地址可用。", systemImage: "checkmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var discoveredCameras: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                    Text("发现相机")
                    .font(.headline)
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
                .padding(14)
                .background(.tertiary.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
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
                    .textFieldStyle(.roundedBorder)

                HStack{
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

private struct CameraDebugLogView: View {
    @ObservedObject var camera: CameraConnectionService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if camera.debugLog.isEmpty {
                    ContentUnavailableView(
                        "暂无连接日志",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("连接相机后，TCP、PTP/IP 报文、解析偏移和失败原因会显示在这里。")
                    )
                } else {
                    ScrollView([.vertical, .horizontal]) {
                        Text(camera.debugLog)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("连接日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        camera.clearDebugLog()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(camera.debugLog.isEmpty)
                    .accessibilityLabel("清空连接日志")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
    }
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
