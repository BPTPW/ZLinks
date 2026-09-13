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
    @State private var editingParameter: CaptureParameter?
    @State private var sliderIndex = 0.0
    @State private var isFullscreenPresented = false

    private let leftRailParameters: [CaptureParameter] = [
        .exposureCompensation,
        .shutterSpeed,
        .aperture,
        .iso,
        .whiteBalance
    ]

    private let rightRailParameters: [CaptureParameter] = [
        .focusMode,
        .meteringMode,
        .exposureMode
    ]

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color(.systemGroupedBackground)
                    .ignoresSafeArea()

                workspace(for: proxy.size)
                    .allowsHitTesting(editingParameter == nil)

                if let parameter = editingParameter,
                   let options = editorOptions(for: parameter) {
                    Color.black.opacity(0.16)
                        .ignoresSafeArea()
                        .onTapGesture {
                            closeEditor()
                        }

                    CaptureSliderEditor(
                        parameter: parameter,
                        options: options,
                        selectedIndex: $sliderIndex,
                        onClose: closeEditor,
                        onValueChanged: { rawValue in
                            camera.queueCaptureParameter(parameter, rawValue: rawValue)
                        }
                    )
                    .padding(24)
                    .frame(maxWidth: 560)
                    .transition(
                        .scale(scale: 0.94)
                            .combined(with: .opacity)
                    )
                    .zIndex(10)
                }
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: editingParameter)
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
        .fullScreenCover(isPresented: $isFullscreenPresented) {
            CaptureFullscreenMonitor(
                showsGrid: $showsGrid,
                mirrorsPreview: $mirrorsPreview,
                editingParameter: $editingParameter,
                sliderIndex: $sliderIndex,
                onDismiss: {
                    editingParameter = nil
                    isFullscreenPresented = false
                }
            )
            .environmentObject(camera)
        }
    }

    @ViewBuilder
    private func workspace(for size: CGSize) -> some View {
        if size.width > size.height {
            landscapeWorkspace
        } else {
            portraitWorkspace
        }
    }

    private var landscapeWorkspace: some View {
        HStack(alignment: .center, spacing: 10) {
            CaptureSideRail(
                title: "曝光",
                parameters: leftRailParameters,
                showsLocalKeys: false,
                showsRefresh: false,
                showsGrid: $showsGrid,
                mirrorsPreview: $mirrorsPreview,
                onSelect: openEditor
            )

            liveViewPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)

            CaptureSideRail(
                title: "对焦 / 监看",
                parameters: rightRailParameters,
                showsLocalKeys: true,
                showsRefresh: true,
                showsGrid: $showsGrid,
                mirrorsPreview: $mirrorsPreview,
                onSelect: openEditor
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var portraitWorkspace: some View {
        ScrollView {
            VStack(spacing: 14) {
                liveViewPanel

                CapturePortraitKeyDeck(
                    showsGrid: $showsGrid,
                    mirrorsPreview: $mirrorsPreview,
                    onSelect: openEditor
                )
            }
            .padding(12)
        }
        .scrollIndicators(.hidden)
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
                HStack(spacing: 8) {
                    liveViewBadge
                    Spacer()
                    Button {
                        isFullscreenPresented = true
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.subheadline.bold())
                            .frame(width: 34, height: 34)
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .accessibilityLabel("全屏监看")
                }
                .padding(12)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .aspectRatio(4.0 / 3.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.13), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.24), radius: 24, y: 12)
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

    private func openEditor(_ parameter: CaptureParameter) {
        guard let options = editorOptions(for: parameter) else { return }
        let current = camera.captureParameters[parameter]
        let index = current.flatMap { value in
            options.firstIndex(where: { $0.rawValue == value })
        } ?? 0

        sliderIndex = Double(index)
        editingParameter = parameter
    }

    private func closeEditor() {
        editingParameter = nil
    }

    private func editorOptions(for parameter: CaptureParameter) -> [CaptureOption]? {
        let options = CaptureOptionCatalog.options(for: parameter)
        return options.isEmpty ? nil : options
    }
}

private struct CaptureFullscreenMonitor: View {
    @EnvironmentObject private var camera: CameraConnectionService
    @Binding var showsGrid: Bool
    @Binding var mirrorsPreview: Bool
    @Binding var editingParameter: CaptureParameter?
    @Binding var sliderIndex: Double
    let onDismiss: () -> Void

    private let leftRailParameters: [CaptureParameter] = [
        .exposureCompensation,
        .shutterSpeed,
        .aperture,
        .iso,
        .whiteBalance
    ]

    private let rightRailParameters: [CaptureParameter] = [
        .focusMode,
        .meteringMode,
        .exposureMode
    ]

    var body: some View {
        GeometryReader { _ in
            ZStack {
                Color.black
                    .ignoresSafeArea()

                HStack(alignment: .center, spacing: 10) {
                    CaptureSideRail(
                        title: "曝光",
                        parameters: leftRailParameters,
                        showsLocalKeys: false,
                        showsRefresh: false,
                        showsGrid: $showsGrid,
                        mirrorsPreview: $mirrorsPreview,
                        onSelect: openEditor
                    )

                    fullscreenVideoSurface

                    CaptureSideRail(
                        title: "对焦 / 监看",
                        parameters: rightRailParameters,
                        showsLocalKeys: true,
                        showsRefresh: true,
                        showsGrid: $showsGrid,
                        mirrorsPreview: $mirrorsPreview,
                        onSelect: openEditor
                    )
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .allowsHitTesting(editingParameter == nil)

                VStack {
                    ZStack {
                        HStack {
                            Spacer()
                            fullscreenStatusBadge
                            Spacer()
                        }

                        HStack {
                            Spacer()
                            Button(action: onDismiss) {
                                Image(systemName: "arrow.down.right.and.arrow.up.left")
                                    .font(.subheadline.bold())
                                    .frame(width: 38, height: 38)
                                    .foregroundStyle(.white)
                            }
                            .buttonStyle(.plain)
                            .glassEffect(.regular.interactive(), in: .circle)
                            .accessibilityLabel("退出全屏监看")
                        }
                    }
                    .padding(16)

                    Spacer()
                }
                .allowsHitTesting(editingParameter == nil)

                if let parameter = editingParameter,
                   let options = editorOptions(for: parameter) {
                    Color.black.opacity(0.22)
                        .ignoresSafeArea()
                        .onTapGesture {
                            editingParameter = nil
                        }

                    CaptureSliderEditor(
                        parameter: parameter,
                        options: options,
                        selectedIndex: $sliderIndex,
                        onClose: { editingParameter = nil },
                        onValueChanged: { rawValue in
                            camera.queueCaptureParameter(parameter, rawValue: rawValue)
                        }
                    )
                    .padding(24)
                    .frame(maxWidth: 560)
                    .transition(
                        .scale(scale: 0.94)
                            .combined(with: .opacity)
                    )
                    .zIndex(10)
                }
            }
            .animation(.spring(response: 0.34, dampingFraction: 0.86), value: editingParameter)
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
    }

    private var fullscreenVideoSurface: some View {
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
                VStack(spacing: 10) {
                    ProgressView()
                        .tint(.white)
                    Text(camera.liveViewError ?? "等待实时画面…")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.82))
                }
            }

            if showsGrid {
                CaptureGridOverlay()
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.13), lineWidth: 1)
        }
    }

    private var fullscreenStatusBadge: some View {
        let isLive = camera.liveViewImage != nil
        return HStack(spacing: 7) {
            Circle()
                .fill(isLive ? Color.green : Color.yellow)
                .frame(width: 8, height: 8)
            Text(isLive ? "全屏实时监看" : "正在启动实时图传")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
    }

    private func openEditor(_ parameter: CaptureParameter) {
        let options = CaptureOptionCatalog.options(for: parameter)
        guard !options.isEmpty else { return }
        let current = camera.captureParameters[parameter]
        let index = current.flatMap { value in
            options.firstIndex(where: { $0.rawValue == value })
        } ?? 0

        sliderIndex = Double(index)
        editingParameter = parameter
    }
}
private struct CaptureSideRail: View {
    @EnvironmentObject private var camera: CameraConnectionService

    let title: String
    let parameters: [CaptureParameter]
    let showsLocalKeys: Bool
    let showsRefresh: Bool
    @Binding var showsGrid: Bool
    @Binding var mirrorsPreview: Bool
    let onSelect: (CaptureParameter) -> Void

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)

                    Spacer(minLength: 0)

                    if showsRefresh {
                        Button {
                            Task { await camera.refreshCaptureParameters() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption.weight(.bold))
                                .frame(width: 26, height: 26)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .circle)
                        .disabled(!isConnected || camera.isRefreshingCaptureParameters || camera.isCaptureControlBusy)
                        .accessibilityLabel("刷新相机参数")
                    }
                }
                .padding(.horizontal, 4)

                ForEach(parameters) { parameter in
                    CaptureGlassKey(
                        title: parameter.title,
                        symbol: parameter.symbol,
                        value: CaptureOptionCatalog.displayedValue(
                            for: parameter,
                            rawValue: camera.captureParameters[parameter]
                        ),
                        style: .rail,
                        isOn: false,
                        isBusy: camera.activeCaptureWrite == parameter,
                        isEnabled: isConnected,
                        action: { onSelect(parameter) }
                    )
                }

                if showsLocalKeys {
                    CaptureGlassKey(
                        title: "网格",
                        symbol: "grid",
                        value: showsGrid ? "开" : "关",
                        style: .rail,
                        isOn: showsGrid,
                        isBusy: false,
                        isEnabled: true
                    ) {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            showsGrid.toggle()
                        }
                    }

                    CaptureGlassKey(
                        title: "镜像",
                        symbol: "arrow.left.and.right",
                        value: mirrorsPreview ? "开" : "关",
                        style: .rail,
                        isOn: mirrorsPreview,
                        isBusy: false,
                        isEnabled: true
                    ) {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            mirrorsPreview.toggle()
                        }
                    }
                }
            }
            .padding(8)
        }
        .scrollIndicators(.hidden)
        .frame(width: 116)
        .frame(maxHeight: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
    }

    private var isConnected: Bool {
        if case .connected = camera.state { return true }
        return false
    }
}

private struct CapturePortraitKeyDeck: View {
    @EnvironmentObject private var camera: CameraConnectionService
    @Binding var showsGrid: Bool
    @Binding var mirrorsPreview: Bool
    let onSelect: (CaptureParameter) -> Void

    private let parameters: [CaptureParameter] = [
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
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 104, maximum: 170), spacing: 10)],
            spacing: 10
        ) {
            ForEach(parameters) { parameter in
                CaptureGlassKey(
                    title: parameter.title,
                    symbol: parameter.symbol,
                    value: CaptureOptionCatalog.displayedValue(
                        for: parameter,
                        rawValue: camera.captureParameters[parameter]
                    ),
                    style: .tile,
                    isOn: false,
                    isBusy: camera.activeCaptureWrite == parameter,
                    isEnabled: isConnected
                ) {
                    onSelect(parameter)
                }
            }

            CaptureGlassKey(
                title: "网格",
                symbol: "grid",
                value: showsGrid ? "开" : "关",
                style: .tile,
                isOn: showsGrid,
                isBusy: false,
                isEnabled: true
            ) {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showsGrid.toggle()
                }
            }

            CaptureGlassKey(
                title: "镜像",
                symbol: "arrow.left.and.right",
                value: mirrorsPreview ? "开" : "关",
                style: .tile,
                isOn: mirrorsPreview,
                isBusy: false,
                isEnabled: true
            ) {
                withAnimation(.easeInOut(duration: 0.18)) {
                    mirrorsPreview.toggle()
                }
            }
        }
    }

    private var isConnected: Bool {
        if case .connected = camera.state { return true }
        return false
    }
}

private enum CaptureKeyStyle {
    case rail
    case tile

    var minHeight: CGFloat {
        switch self {
        case .rail: return 40
        case .tile: return 76
        }
    }

    var padding: CGFloat {
        switch self {
        case .rail: return 6
        case .tile: return 11
        }
    }

    var valueFont: Font {
        switch self {
        case .rail: return .headline.monospacedDigit().weight(.bold)
        case .tile: return .title3.monospacedDigit().weight(.bold)
        }
    }
}

private struct CaptureGlassKey: View {
    let title: String
    let symbol: String
    let value: String
    let style: CaptureKeyStyle
    let isOn: Bool
    let isBusy: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    Image(systemName: symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isOn ? Color.orange : Color.primary)

                    Spacer(minLength: 0)

                    if isBusy {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                }

                Text(value)
                    .font(style.valueFont)
                    .lineLimit(1)
                    .minimumScaleFactor(0.52)

                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, minHeight: style.minHeight, alignment: .leading)
            .padding(style.padding)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    isOn ? Color.orange.opacity(0.72) : Color.white.opacity(0.09),
                    lineWidth: 1
                )
        }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.46)
        .accessibilityLabel("\(title)，\(value)")
    }
}

private struct CaptureSliderEditor: View {
    @EnvironmentObject private var camera: CameraConnectionService

    let parameter: CaptureParameter
    let options: [CaptureOption]
    @Binding var selectedIndex: Double
    let onClose: () -> Void
    let onValueChanged: (UInt64) -> Void

    private var safeIndex: Int {
        min(max(Int(selectedIndex.rounded()), 0), options.count - 1)
    }

    private var selectedOption: CaptureOption {
        options[safeIndex]
    }

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: parameter.symbol)
                    .font(.headline)
                    .frame(width: 34, height: 34)
                    .glassEffect(.regular, in: .circle)

                VStack(alignment: .leading, spacing: 2) {
                    Text(parameter.title)
                        .font(.headline)
                    Text("拖动滑杆实时调节")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.subheadline.bold())
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("关闭参数滑杆")
            }

            Text(selectedOption.title)
                .font(.system(size: 42, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .contentTransition(.numericText())

            VStack(spacing: 8) {
                Slider(value: sliderBinding, in: 0...Double(max(options.count - 1, 1)), step: 1)
                    .tint(.orange)

                HStack {
                    Text(options.first?.title ?? "--")
                    Spacer()
                    Text("\(safeIndex + 1) / \(options.count)")
                    Spacer()
                    Text(options.last?.title ?? "--")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            if camera.isCaptureControlBusy {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在同步到相机…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .transition(.opacity)
            }
        }
        .padding(22)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 30))
        .shadow(color: .black.opacity(0.28), radius: 32, y: 18)
    }

    private var sliderBinding: Binding<Double> {
        Binding(
            get: { selectedIndex },
            set: { newValue in
                selectedIndex = newValue
                let index = min(max(Int(newValue.rounded()), 0), options.count - 1)
                onValueChanged(options[index].rawValue)
            }
        )
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
