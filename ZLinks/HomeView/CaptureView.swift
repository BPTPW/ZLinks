//
//  CaptureView.swift
//  ZLinks
//

import SwiftUI
import UIKit

struct CaptureView: View {
    @EnvironmentObject private var camera: CameraConnectionService
    @State private var showsGrid = true
    @State private var mirrorsPreview = false

    var body: some View {
        GeometryReader { proxy in
            Group {
                if proxy.size.width > proxy.size.height {
                    HStack(spacing: 12) {
                        liveViewPanel
                            .layoutPriority(1)

                        CaptureControlsPanel(
                            showsGrid: $showsGrid,
                            mirrorsPreview: $mirrorsPreview
                        )
                        .frame(width: min(max(proxy.size.width * 0.48, 430), 650))
                    }
                    .padding(12)
                } else {
                    ScrollView {
                        VStack(spacing: 12) {
                            liveViewPanel

                            CaptureControlsPanel(
                                showsGrid: $showsGrid,
                                mirrorsPreview: $mirrorsPreview
                            )
                        }
                        .padding(12)
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .task(id: liveViewSessionKey) {
            await camera.startLiveView()
            await camera.refreshCaptureParameters()

            await withTaskCancellationHandler {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(3600))
                }
            } onCancel: {
                Task { @MainActor in
                    await camera.stopLiveView()
                }
            }
            await camera.stopLiveView()
        }
    }

    private var liveViewSessionKey: String {
        switch camera.state {
        case .connected:
            return "connected:\(camera.connectedHost ?? "")"
        case .connecting:
            return "connecting"
        case .failed(let message):
            return "failed:\(message)"
        case .disconnected:
            return "disconnected"
        }
    }

    private var liveViewPanel: some View {
        ZStack {
            Color.black

            if let image = camera.liveViewImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .scaleEffect(x: mirrorsPreview ? -1 : 1, y: 1)
                    .animation(.easeInOut(duration: 0.18), value: mirrorsPreview)
            } else {
                liveViewPlaceholder
            }

            if showsGrid {
                CaptureGridOverlay()
                    .allowsHitTesting(false)
            }

            VStack {
                HStack {
                    liveViewBadge
                    Spacer()
                }
                .padding(12)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(4.0 / 3.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
    }

    private var liveViewPlaceholder: some View {
        VStack(spacing: 10) {
            if case .connecting = camera.state {
                ProgressView()
                    .tint(.white)
                Text("正在连接相机…")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
            } else if case .connected = camera.state {
                if camera.isLiveViewActive {
                    ProgressView()
                        .tint(.white)
                    Text("正在获取实时画面…")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                } else if let liveViewError = camera.liveViewError {
                    Image(systemName: "video.slash")
                        .font(.title2)
                        .foregroundStyle(.white.opacity(0.8))
                    Text(liveViewError)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 24)
                } else {
                    ProgressView()
                        .tint(.white)
                    Text("准备实时图传…")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                }
            } else {
                Image(systemName: "camera.metering.none")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.8))
                Text("连接相机后显示实时画面")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var liveViewBadge: some View {
        let title: String
        let color: Color
        switch camera.state {
        case .connected where camera.liveViewImage != nil:
            title = "实时"
            color = .green
        case .connected where camera.isLiveViewActive:
            title = "启动中"
            color = .yellow
        case .connected:
            title = camera.liveViewError == nil ? "等待图传" : "不可用"
            color = camera.liveViewError == nil ? .yellow : .orange
        case .connecting:
            title = "连接中"
            color = .yellow
        default:
            title = "未连接"
            color = .gray
        }

        return HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black.opacity(0.45), in: Capsule())
    }
}

private struct CaptureControlsPanel: View {
    @EnvironmentObject private var camera: CameraConnectionService
    @Binding var showsGrid: Bool
    @Binding var mirrorsPreview: Bool

    private let cameraKeys: [CaptureParameter] = [
        .exposureCompensation,
        .shutterSpeed,
        .aperture,
        .focusMode,
        .iso,
        .whiteBalance,
        .meteringMode,
        .exposureMode
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("实体按键")
                    .font(.headline)

                if camera.isRefreshingCaptureParameters {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer(minLength: 8)

                Button {
                    Task { await camera.refreshCaptureParameters() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .disabled(!isConnected || camera.isRefreshingCaptureParameters || camera.activeCaptureWrite != nil)
            }

            CaptureReadoutBar()

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 104, maximum: 170), spacing: 10)],
                spacing: 10
            ) {
                ForEach(cameraKeys) { parameter in
                    let options = CaptureOptionCatalog.options(for: parameter)
                    let currentValue = camera.captureParameters[parameter]
                    CapturePhysicalKey(
                        title: parameter.title,
                        symbol: parameter.symbol,
                        value: CaptureOptionCatalog.displayedValue(for: parameter, rawValue: currentValue),
                        isOn: false,
                        isBusy: camera.activeCaptureWrite == parameter,
                        isEnabled: isConnected && camera.activeCaptureWrite == nil && !options.isEmpty
                    ) {
                        cycle(parameter)
                    }
                }

                CapturePhysicalKey(
                    title: "网格",
                    symbol: "grid",
                    value: showsGrid ? "开" : "关",
                    isOn: showsGrid,
                    isBusy: false,
                    isEnabled: true
                ) {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showsGrid.toggle()
                    }
                }

                CapturePhysicalKey(
                    title: "镜像",
                    symbol: "arrow.left.and.right",
                    value: mirrorsPreview ? "开" : "关",
                    isOn: mirrorsPreview,
                    isBusy: false,
                    isEnabled: true
                ) {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        mirrorsPreview.toggle()
                    }
                }
            }

            if let error = camera.captureControlError {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        camera.clearCaptureControlError()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.bold())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭参数错误提示")
                }
                .padding(10)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.primary.opacity(0.1), lineWidth: 1)
        }
    }

    private var isConnected: Bool {
        if case .connected = camera.state { return true }
        return false
    }

    private func cycle(_ parameter: CaptureParameter) {
        let options = CaptureOptionCatalog.options(for: parameter)
        guard !options.isEmpty else { return }

        let current = camera.captureParameters[parameter]
        let next: CaptureOption
        if let current, let index = options.firstIndex(where: { $0.rawValue == current }) {
            next = options[(index + 1) % options.count]
        } else {
            next = options[0]
        }

        Task {
            await camera.setCaptureParameter(parameter, rawValue: next.rawValue)
        }
    }
}

private struct CaptureReadoutBar: View {
    @EnvironmentObject private var camera: CameraConnectionService

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                readout(.exposureMode, title: "模式")
                readout(.shutterSpeed, title: "快门")
                readout(.aperture, title: "光圈")
                readout(.iso, title: "ISO")
                readout(.whiteBalance, title: "白平衡")
            }
        }
        .scrollIndicators(.hidden)
    }

    private func readout(_ parameter: CaptureParameter, title: String) -> some View {
        let value = CaptureOptionCatalog.displayedValue(
            for: parameter,
            rawValue: camera.captureParameters[parameter]
        )
        return VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .frame(minWidth: 64, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct CapturePhysicalKey: View {
    let title: String
    let symbol: String
    let value: String
    let isOn: Bool
    let isBusy: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: symbol)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(isOn ? Color.orange : Color.primary)
                    Spacer(minLength: 4)
                    if isBusy {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.tertiary)
                    }
                }

                Text(value)
                    .font(.title3.monospacedDigit().weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)

                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
            .padding(11)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isOn ? Color.orange.opacity(0.65) : Color.primary.opacity(0.08), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || isBusy)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityLabel("\(title)，\(value)")
    }
}

private struct CaptureGridOverlay: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            for index in 1..<3 {
                let fraction = CGFloat(index) / 3
                let x = size.width * fraction
                let y = size.height * fraction
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }

            context.stroke(
                path,
                with: .color(.white.opacity(0.48)),
                style: StrokeStyle(lineWidth: 1, dash: [6, 4])
            )
        }
    }
}

#Preview {
    CaptureView()
        .environmentObject(CameraConnectionService())
}
