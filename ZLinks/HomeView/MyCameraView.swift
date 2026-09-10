//
//  MyCameraView.swift
//  ZLinks
//

import SwiftUI

struct MyCameraView: View {
    @StateObject private var camera = CameraConnectionService()
    @State private var isConnectionSheetPresented = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    cameraStatusCard

                    if case .connected = camera.state {
                        connectionDetails
                    } else {
                        preparationSection
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
            .navigationTitle("我的相机")
            .navigationBarTitleDisplayMode(.large)
            .sheet(isPresented: $isConnectionSheetPresented) {
                CameraConnectionSheet(camera: camera)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    .presentationCornerRadius(28)
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

                statusLabel
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

    private var connectionDetails: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("相机状态")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await camera.refreshCameraStatus() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.glass)
                .accessibilityLabel("刷新相机状态")
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                statusMetric(
                    title: "电量",
                    value: camera.cameraStatus.batteryLevel.map { "\($0)%" } ?? "不可用",
                    symbol: batterySymbol
                )
                statusMetric(
                    title: "存储空间",
                    value: storageValue,
                    symbol: "sdcard"
                )
                statusMetric(
                    title: "可用空间",
                    value: camera.cameraStatus.storageFreeBytes.map(formatBytes) ?? "不可用",
                    symbol: "externaldrive"
                )
                statusMetric(
                    title: "媒体文件",
                    value: camera.cameraStatus.mediaObjectCount.map { "\($0)" } ?? "不可用",
                    symbol: "photo.stack"
                )
            }

            VStack(spacing: 12) {
                detailRow("网络地址", value: camera.connectedHost ?? "-")
                if let storageName = camera.cameraStatus.storageName, !storageName.isEmpty {
                    detailRow("存储卡", value: storageName)
                }
                if let serialNumber = camera.cameraInfo?.serialNumber, !serialNumber.isEmpty {
                    detailRow("序列号", value: serialNumber)
                }
                detailRow("协议", value: "PTP/IP")
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }

    private var preparationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("连接准备")
                .font(.headline)
            Text("请先让 iPhone 与相机处于同一个 Wi-Fi 网络，或加入相机创建的 Wi-Fi 网络。连接后会读取相机品牌、型号和序列号。")
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
            return .secondary
        case .failed:
            return .red
        }
    }

    private var connectionStatusTitle: String {
        switch camera.state {
        case .connected:
            return "已连接"
        case .connecting:
            return "连接中"
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
            return "正在连接"
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

    private func detailRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }

    private var batterySymbol: String {
        guard let level = camera.cameraStatus.batteryLevel else { return "battery.0" }
        switch level {
        case 76...:
            return "battery.100percent"
        case 51...75:
            return "battery.75percent"
        case 26...50:
            return "battery.50percent"
        default:
            return "battery.25percent"
        }
    }

    private var storageValue: String {
        guard let free = camera.cameraStatus.storageFreeBytes,
              let total = camera.cameraStatus.storageTotalBytes else {
            return "不可用"
        }
        return "\(formatBytes(free)) / \(formatBytes(total))"
    }

    private func statusMetric(title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol)
                .font(.headline)
                .foregroundStyle(.blue)
            Text(value)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
        .padding(14)
        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
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
    @State private var selectedMode: ConnectionMode = .accessPoint
    @State private var isConnecting = false

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
                        discoveredCameras

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

                scanButton
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
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
                discovery.start()
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
                discovery.start()
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
                    "在 iPhone 的 Wi-Fi 设置中加入相机显示的网络。",
                    "回到 ZLinks 后，应用会自动扫描相机所在的 Wi-Fi 网络。",
                    "从发现的相机列表中选择设备并读取基础信息。"
                ],
                note: "相机 Wi-Fi 不提供互联网时，iOS 决定是否回落蜂窝数据。请在“设置 > 蜂窝网络”中允许 ZLinks 使用蜂窝数据；应用无法通过公开 API 强制系统的 Wi-Fi 与蜂窝路由策略。"
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
                .buttonStyle(.glass)
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

    private var scanButton: some View {
        Button {
            discovery.start()
        } label: {
            HStack(spacing: 10) {
                if discovery.isSearching {
                    ProgressView()
                }
                Text(discovery.isSearching ? "正在扫描相机" : "重新扫描相机")
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .disabled(discovery.isSearching || isConnecting)
        .accessibilityIdentifier("scanCameraNetworkButton")
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
