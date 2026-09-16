//
//  CaptureView.swift
//  ZLinks
//

import SwiftUI
import UIKit

private enum CapturePreferenceKey {
    static let showsGrid = "capture.showsGrid"
    static let mirrorsPreview = "capture.mirrorsPreview"
}

private extension CameraConnectionService {
    func isCaptureParameterAutoLocked(_ parameter: CaptureParameter) -> Bool {
        !parameter.isAdjustable(in: captureExposureMode)
    }

    func canOpenCaptureParameterEditor(_ parameter: CaptureParameter) -> Bool {
        !captureOptions(for: parameter).isEmpty && (
            canAdjustCaptureParameter(parameter) || isCaptureParameterAutoLocked(parameter)
        )
    }
}

struct CaptureView: View {
    @EnvironmentObject private var camera: CameraConnectionService
    @AppStorage(CapturePreferenceKey.showsGrid) private var showsGrid = false
    @AppStorage(CapturePreferenceKey.mirrorsPreview) private var mirrorsPreview = false
    @State private var editingParameter: CaptureParameter?
    @State private var sliderIndex = 0.0
    @State private var isRefreshIntervalEditorPresented = false
    @State private var refreshIntervalSliderIndex = 0.0
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
        .meteringMode
    ]

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color(.systemGroupedBackground)
                    .ignoresSafeArea()

                workspace(for: proxy.size)
                    .allowsHitTesting(editingParameter == nil && !isRefreshIntervalEditorPresented)

                if let parameter = editingParameter,
                   let options = editorOptions(for: parameter)
                {
                    Color.black.opacity(0.16)
                        .ignoresSafeArea()
                        .onTapGesture {
                            closeEditor()
                        }

                    CaptureSliderEditor(
                        parameter: parameter,
                        options: options,
                        selectedIndex: $sliderIndex,
                        isAutoLocked: camera.isCaptureParameterAutoLocked(parameter),
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

                if isRefreshIntervalEditorPresented {
                    Color.black.opacity(0.16)
                        .ignoresSafeArea()
                        .onTapGesture {
                            closeRefreshIntervalEditor()
                        }

                    CaptureRefreshIntervalEditor(
                        selectedIndex: $refreshIntervalSliderIndex,
                        onClose: closeRefreshIntervalEditor,
                        onValueChanged: camera.setLiveViewRefreshInterval
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
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: isRefreshIntervalEditorPresented)
        .task(id: liveViewSessionKey) {
            await camera.startLiveView()
            await camera.refreshCaptureParameterCapabilities()
            await camera.refreshCaptureParameters()

            await withTaskCancellationHandler {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    if Task.isCancelled { break }
                    await camera.refreshCaptureParameters()
                }
            } onCancel: {
                Task { @MainActor in
                    await camera.stopLiveView()
                }
            }
            await camera.stopLiveView()
        }
        .task(id: camera.state) {
            await camera.refreshCameraStatusPeriodically()
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
                showsGrid: $showsGrid,
                mirrorsPreview: $mirrorsPreview,
                onSelect: openEditor
            )

            VStack(spacing: 8) {
                CaptureLiveViewStatusBar()
                liveViewPanel(showsPortraitCaptureButton: false)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)

            CaptureSideRail(
                title: "对焦 / 监看",
                parameters: rightRailParameters,
                showsLocalKeys: true,
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
                CaptureLiveViewStatusBar()
                liveViewPanel(showsPortraitCaptureButton: true)

                CapturePortraitKeyDeck(
                    showsGrid: $showsGrid,
                    mirrorsPreview: $mirrorsPreview,
                    onSelect: openEditor,
                    onSelectRefreshInterval: openRefreshIntervalEditor
                )
            }
            .padding(12)
        }
        .scrollIndicators(.hidden)
    }

    private func liveViewPanel(showsPortraitCaptureButton: Bool) -> some View {
        ZStack {
            Color.black

            if let image = camera.liveViewImage {
                CaptureLiveViewImageSurface(
                    image: image,
                    mirrorsPreview: mirrorsPreview
                )
            } else {
                liveViewPlaceholder
            }

            if showsGrid {
                CaptureGridOverlay()
                    .allowsHitTesting(false)
            }

            GeometryReader { proxy in
                CaptureExposureScale(
                    rawValue: camera.captureParameters[.exposureCompensation],
                    options: camera.captureOptions(for: .exposureCompensation),
                    onCommit: { camera.queueCaptureParameter(.exposureCompensation, rawValue: $0) }
                )
                .frame(width: 62, height: proxy.size.height / 3 + 42)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            }

            GeometryReader { _ in
                VStack {
                    Spacer()
                    HStack {
                        if showsPortraitCaptureButton {
                            Button {
                                Task { await camera.initiateCaptureRecInMedia() }
                            } label: {
                                Circle()
                                    .fill(.white)
                                    .frame(width: 34, height: 34)
                                    .padding(8)
                            }
                            .buttonStyle(.plain)
                            .background(.black.opacity(0.34), in: Circle())
                            .disabled(!isConnected || camera.isInitiatingCapture)
                            .opacity(isConnected ? 1 : 0.42)
                            .accessibilityLabel("拍摄")
                        }

                        Spacer()

                        Button {
                            isFullscreenPresented = true
                        } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.subheadline.bold())
                                .frame(width: 34, height: 34)
                                .foregroundStyle(.primary)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .circle)
                        .accessibilityLabel("全屏监看")
                    }
                }
                .padding(12)
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

    private var isConnected: Bool {
        if case .connected = camera.state { return true }
        return false
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
        guard camera.canOpenCaptureParameterEditor(parameter) else { return }
        guard let options = editorOptions(for: parameter) else { return }
        let current = camera.captureParameters[parameter]
        let index = current.flatMap { value in
            options.firstIndex(where: { $0.rawValue == value })
        } ?? 0

        sliderIndex = Double(index)
        isRefreshIntervalEditorPresented = false
        editingParameter = parameter
    }

    private func closeEditor() {
        editingParameter = nil
    }

    private func openRefreshIntervalEditor() {
        let options = LiveViewRefreshInterval.allCases
        refreshIntervalSliderIndex = Double(
            options.firstIndex(of: camera.liveViewRefreshInterval) ?? 0
        )
        editingParameter = nil
        isRefreshIntervalEditorPresented = true
    }

    private func closeRefreshIntervalEditor() {
        isRefreshIntervalEditorPresented = false
    }

    private func editorOptions(for parameter: CaptureParameter) -> [CaptureOption]? {
        guard parameter != .exposureMode else { return nil }
        let options = camera.captureOptions(for: parameter)
        return options.isEmpty ? nil : options
    }
}

private struct CaptureLiveViewImageSurface: View {
    @EnvironmentObject private var camera: CameraConnectionService
    let image: UIImage
    let mirrorsPreview: Bool

    var body: some View {
        GeometryReader { proxy in
            let imageRect = aspectFitRect(for: image.size, in: proxy.size)

            ZStack(alignment: .topLeading) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .scaleEffect(x: mirrorsPreview ? -1 : 1, y: 1)
                    .animation(.easeInOut(duration: 0.18), value: mirrorsPreview)

                if camera.isLiveViewFocusPointAvailable,
                   let focusPoint = camera.liveViewFocusPoint
                {
                    Rectangle()
                        .stroke(.red, lineWidth: 2)
                        .frame(
                            width: max(18, imageRect.width * focusPoint.frameSize.width),
                            height: max(18, imageRect.height * focusPoint.frameSize.height)
                        )
                        .position(
                            x: imageRect.minX + imageRect.width * displayedX(focusPoint.position.x),
                            y: imageRect.minY + imageRect.height * focusPoint.position.y
                        )
                        .allowsHitTesting(false)
                }

                Color.clear
                    .frame(width: imageRect.width, height: imageRect.height)
                    .contentShape(Rectangle())
                    .position(x: imageRect.midX, y: imageRect.midY)
                    .allowsHitTesting(
                        camera.isLiveViewFocusPointAvailable
                            && !camera.isSettingLiveViewFocusPoint
                    )
                    .gesture(
                        SpatialTapGesture()
                            .onEnded { value in
                                let displayedPoint = CGPoint(
                                    x: value.location.x / max(imageRect.width, 1),
                                    y: value.location.y / max(imageRect.height, 1)
                                )
                                let cameraPoint = CGPoint(
                                    x: mirrorsPreview ? 1 - displayedPoint.x : displayedPoint.x,
                                    y: displayedPoint.y
                                )
                                Task {
                                    await camera.setLiveViewFocusPoint(
                                        normalizedToDisplayedImage: cameraPoint
                                    )
                                }
                            }
                    )
                    .accessibilityLabel("设置对焦点")
            }
        }
    }

    private func displayedX(_ cameraX: CGFloat) -> CGFloat {
        mirrorsPreview ? 1 - cameraX : cameraX
    }

    private func aspectFitRect(for imageSize: CGSize, in containerSize: CGSize) -> CGRect {
        guard imageSize.width > 0,
              imageSize.height > 0,
              containerSize.width > 0,
              containerSize.height > 0
        else { return .zero }

        let scale = min(
            containerSize.width / imageSize.width,
            containerSize.height / imageSize.height
        )
        let fittedSize = CGSize(
            width: imageSize.width * scale,
            height: imageSize.height * scale
        )
        return CGRect(
            x: (containerSize.width - fittedSize.width) / 2,
            y: (containerSize.height - fittedSize.height) / 2,
            width: fittedSize.width,
            height: fittedSize.height
        )
    }
}

private struct CaptureFullscreenMonitor: View {
    @EnvironmentObject private var camera: CameraConnectionService
    @Binding var showsGrid: Bool
    @Binding var mirrorsPreview: Bool
    @Binding var editingParameter: CaptureParameter?
    @Binding var sliderIndex: Double
    let onDismiss: () -> Void
    @State private var showsMoreOptions = false

    private let leftRailParameters: [CaptureParameter] = [
        .exposureCompensation,
        .shutterSpeed,
        .aperture,
        .iso,
        .whiteBalance
    ]

    private let rightRailParameters: [CaptureParameter] = [
        .focusMode,
        .meteringMode
    ]

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                    .ignoresSafeArea()

                fullscreenCanvas(for: proxy.size)
                    .frame(width: proxy.size.height, height: proxy.size.width)
                    .rotationEffect(.degrees(90))
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
    }

    @ViewBuilder
    private func fullscreenCanvas(for screenSize: CGSize) -> some View {
        let canvasSize = CGSize(width: screenSize.height, height: screenSize.width)
        let sideColumnMinWidth: CGFloat = 120
        let availablePreviewWidth = max(
            0,
            canvasSize.width - (sideColumnMinWidth * 2)
        )
        let availablePreviewHeight = max(0, canvasSize.height)
        let previewWidth = min(availablePreviewWidth, availablePreviewHeight * 4 / 3)
        let sideColumnWidth = max(sideColumnMinWidth, (canvasSize.width - availablePreviewWidth) / 2)

        ZStack {
            VStack(spacing: 8) {
                HStack(alignment: .center) {
                    CaptureFullscreenReadouts(
                        parameters: leftRailParameters,
                        onSelect: openEditor
                    )
                    .frame(width: sideColumnWidth - 30, alignment: .leading)

                    fullscreenVideoSurface
                        .frame(width: previewWidth, height: previewWidth * 3 / 4)

                    fullscreenRightControls
                        .frame(width: sideColumnWidth + 30)
                        .frame(maxHeight: .infinity)
                }
                .frame(maxHeight: .infinity)
            }
            .allowsHitTesting(editingParameter == nil)

            if showsMoreOptions {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            showsMoreOptions = false
                        }
                    }
                    .zIndex(1)

                CaptureFullscreenMoreOptions(
                    parameters: rightRailParameters,
                    showsGrid: $showsGrid,
                    mirrorsPreview: $mirrorsPreview,
                    onSelect: { parameter in
                        showsMoreOptions = false
                        openEditor(parameter)
                    }
                )
                .frame(width: min(100, canvasSize.width * 0.3))
                .padding(.trailing, sideColumnWidth)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .transition(
                    .scale(scale: 0.08, anchor: .bottomTrailing)
                        .combined(with: .opacity)
                )
                .zIndex(2)
            }

            if let parameter = editingParameter {
                let options = camera.captureOptions(for: parameter)
                if !options.isEmpty {
                    Color.black.opacity(0.22)
                        .ignoresSafeArea()
                        .onTapGesture {
                            editingParameter = nil
                        }

                    CaptureSliderEditor(
                        parameter: parameter,
                        options: options,
                        selectedIndex: $sliderIndex,
                        isAutoLocked: camera.isCaptureParameterAutoLocked(parameter),
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
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: editingParameter)
    }

    private var fullscreenRightControls: some View {
        HStack(spacing: 14) {
            Button {
                Task { await camera.initiateCaptureRecInMedia() }
            } label: {
                Circle()
                    .fill(.white)
                    .frame(width: 56, height: 56)
            }
            .buttonStyle(.plain)
            .disabled(!isConnected || camera.isInitiatingCapture)
            .opacity(isConnected ? 1 : 0.42)
            .accessibilityLabel("拍摄")

            VStack {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.subheadline.bold())
                        .frame(width: 38, height: 38)
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .background(.black.opacity(0.5), in: .circle)
                .accessibilityLabel("退出全屏监看")

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showsMoreOptions.toggle()
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.headline.weight(.bold))
                        .frame(width: 38, height: 38)
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .background(.black.opacity(0.5), in: .circle)
                .accessibilityLabel("更多")
            }
        }
    }

    private var fullscreenVideoSurface: some View {
        ZStack {
            Color.black

            if let image = camera.liveViewImage {
                CaptureLiveViewImageSurface(
                    image: image,
                    mirrorsPreview: mirrorsPreview
                )
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                        .tint(.white)
                    Text(camera.liveViewError ?? "等待图传…")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.82))
                }
            }

            if showsGrid {
                CaptureGridOverlay()
                    .allowsHitTesting(false)
            }

            GeometryReader { proxy in
                CaptureExposureScale(
                    rawValue: camera.captureParameters[.exposureCompensation],
                    options: camera.captureOptions(for: .exposureCompensation),
                    onCommit: { camera.queueCaptureParameter(.exposureCompensation, rawValue: $0) }
                )
                .frame(width: 62, height: proxy.size.height / 3 + 42)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            }

            CaptureFullscreenVideoStatusOverlay()
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func openEditor(_ parameter: CaptureParameter) {
        guard camera.canOpenCaptureParameterEditor(parameter) else { return }
        guard parameter != .exposureMode else { return }
        let options = camera.captureOptions(for: parameter)
        guard !options.isEmpty else { return }
        let current = camera.captureParameters[parameter]
        let index = current.flatMap { value in
            options.firstIndex(where: { $0.rawValue == value })
        } ?? 0

        sliderIndex = Double(index)
        editingParameter = parameter
    }

    private var isConnected: Bool {
        if case .connected = camera.state { return true }
        return false
    }
}

private struct CaptureFullscreenVideoStatusOverlay: View {
    @EnvironmentObject private var camera: CameraConnectionService

    private var connectionTitle: String {
        switch camera.state {
        case .connected where camera.liveViewImage != nil:
            return "实时"
        case .connected where camera.isLiveViewActive:
            return "启动中"
        case .connected:
            return camera.liveViewError == nil ? "等待图传" : "不可用"
        case .connecting:
            return "连接中"
        default:
            return "未连接"
        }
    }

    private var connectionColor: Color {
        switch camera.state {
        case .connected where camera.liveViewImage != nil:
            return .green
        case .connected where camera.isLiveViewActive:
            return .yellow
        case .connected:
            return camera.liveViewError == nil ? .yellow : .orange
        case .connecting:
            return .yellow
        default:
            return .gray
        }
    }

    private var exposureModeText: String {
        CaptureOptionCatalog.displayedValue(
            for: .exposureMode,
            rawValue: camera.captureParameters[.exposureMode]
        )
    }

    private var frameRateText: String {
        guard let frameRate = camera.liveViewFrameRate else { return "-- fps" }
        return String(format: "%.1f fps", frameRate)
    }

    private var batteryText: String {
        guard case .connected = camera.state,
              let batteryLevel = camera.cameraStatus.batteryLevel
        else { return "--%" }
        return "\(batteryLevel)%"
    }

    private var batteryColor: Color {
        guard case .connected = camera.state,
              let batteryLevel = camera.cameraStatus.batteryLevel
        else { return .white }
        switch batteryLevel {
        case 0..<10:
            return .red
        case 10..<20:
            return .orange
        default:
            return .white
        }
    }

    private var storageUsedRatio: Double {
        guard let free = camera.cameraStatus.storageFreeBytes,
              let total = camera.cameraStatus.storageTotalBytes,
              total > 0
        else { return 0 }
        let used = total > free ? total - free : 0
        return min(max(Double(used) / Double(total), 0), 1)
    }

    private var storageUsedText: String {
        guard let free = camera.cameraStatus.storageFreeBytes,
              let total = camera.cameraStatus.storageTotalBytes
        else { return "-- /" }
        let used = total > free ? total - free : 0
        return "\(formatBytes(used)) /"
    }

    private var isStorageLow: Bool {
        guard let free = camera.cameraStatus.storageFreeBytes,
              let total = camera.cameraStatus.storageTotalBytes,
              total > 0
        else { return false }
        return Double(free) / Double(total) < 0.1
    }

    private var storageTotalText: String {
        guard let total = camera.cameraStatus.storageTotalBytes else { return "--" }
        return formatBytes(total)
    }

    var body: some View {
        ZStack {
            VStack {
                HStack(alignment: .top) {
                    connectionReadout
                    Spacer()
                    HStack(spacing: 6) {
                        statusValue(exposureModeText, color: exposureModeText == "AUTO" ? .green : .white)
                            .frame(width: 36)
                        statusValue(frameRateText)
                            .frame(width: 66)
                        statusValue(batteryText, color: batteryColor)
                            .frame(width: 44)
                    }
                }
                Spacer()
            }

            VStack {
                Spacer()
                HStack {
                    storageReadout
                    Spacer()
                }
            }
        }
        .padding(12)
    }

    private var connectionReadout: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(connectionColor)
                .frame(width: 8, height: 8)
            Text(connectionTitle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.black.opacity(0.52), in: Capsule())
    }

    private var storageReadout: some View {
        HStack(spacing: 10) {
            Image(systemName: "sdcard.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)

            VStack(alignment: .leading, spacing: 4) {
                Text(storageUsedText)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(isStorageLow ? .orange : .white)
                    .lineLimit(1)

                Text(storageTotalText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.white.opacity(0.32))
                        Capsule()
                            .fill(isStorageLow ? .orange : .white)
                            .frame(width: proxy.size.width * storageUsedRatio)
                    }
                }
                .frame(height: 4)
            }
            .frame(width: 76)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(.black.opacity(0.52), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func statusValue(_ value: String, color: Color = .white) -> some View {
        Text(value)
            .font(.caption.weight(.bold).monospacedDigit())
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .shadow(color: .black.opacity(0.9), radius: 3, x: 0, y: 1)
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary)
    }
}

private struct CaptureFullscreenReadouts: View {
    @EnvironmentObject private var camera: CameraConnectionService
    let parameters: [CaptureParameter]
    let onSelect: (CaptureParameter) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(parameters) { parameter in
                let isAutoLocked = camera.isCaptureParameterAutoLocked(parameter)
                let isEnabled = isConnected && camera.canOpenCaptureParameterEditor(parameter)
                Button {
                    onSelect(parameter)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: parameter.symbol)
                            .font(.body.weight(.semibold))
                            .frame(width: 22, alignment: .leading)
                            .foregroundStyle(.white.opacity(0.82))

                        Text(
                            CaptureOptionCatalog.displayedValue(
                                for: parameter,
                                rawValue: camera.captureParameters[parameter]
                            )
                        )
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)

                        if isAutoLocked {
                            CaptureAutoBadge()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .disabled(!isEnabled)
                .opacity(isEnabled ? 1 : 0.42)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .accessibilityLabel(
                    "\(parameter.title)，\(CaptureOptionCatalog.displayedValue(for: parameter, rawValue: camera.captureParameters[parameter]))" +
                        (isAutoLocked ? "，自动" : "")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var isConnected: Bool {
        if case .connected = camera.state { return true }
        return false
    }
}

private struct CaptureFullscreenMoreOptions: View {
    @EnvironmentObject private var camera: CameraConnectionService
    let parameters: [CaptureParameter]
    @Binding var showsGrid: Bool
    @Binding var mirrorsPreview: Bool
    let onSelect: (CaptureParameter) -> Void

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 8) {
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
                        isAutoLocked: camera.isCaptureParameterAutoLocked(parameter),
                        isEnabled: isConnected && camera.canOpenCaptureParameterEditor(parameter),
                        action: { onSelect(parameter) }
                    )
                }

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
            .padding(12)
        }
        .scrollIndicators(.hidden)
        .background(.black.opacity(0.86), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 1)
        }
    }

    private var isConnected: Bool {
        if case .connected = camera.state { return true }
        return false
    }
}

private struct CaptureSideRail: View {
    @EnvironmentObject private var camera: CameraConnectionService

    let title: String
    let parameters: [CaptureParameter]
    let showsLocalKeys: Bool
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
                        isAutoLocked: camera.isCaptureParameterAutoLocked(parameter),
                        isEnabled: isConnected && camera.canOpenCaptureParameterEditor(parameter),
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
    let onSelectRefreshInterval: () -> Void

    private let parameters: [CaptureParameter] = [
        .exposureCompensation,
        .shutterSpeed,
        .aperture,
        .focusMode,
        .iso,
        .whiteBalance,
        .meteringMode
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
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
                        isAutoLocked: camera.isCaptureParameterAutoLocked(parameter),
                        isEnabled: isConnected && camera.canOpenCaptureParameterEditor(parameter)
                    ) {
                        onSelect(parameter)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("监看")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 104, maximum: 170), spacing: 10)],
                    spacing: 10
                ) {
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

                    CaptureGlassKey(
                        title: "图传刷新频率",
                        symbol: "arrow.triangle.2.circlepath",
                        value: camera.liveViewRefreshInterval.title,
                        style: .tile,
                        isOn: false,
                        isBusy: false,
                        isEnabled: true,
                        action: onSelectRefreshInterval
                    )
                }
            }
        }
    }

    private var isConnected: Bool {
        if case .connected = camera.state { return true }
        return false
    }
}

private struct CaptureRefreshIntervalEditor: View {
    @Binding var selectedIndex: Double
    let onClose: () -> Void
    let onValueChanged: (LiveViewRefreshInterval) -> Void

    private let options = LiveViewRefreshInterval.allCases

    private var safeIndex: Int {
        min(max(Int(selectedIndex.rounded()), 0), options.count - 1)
    }

    private var selectedOption: LiveViewRefreshInterval {
        options[safeIndex]
    }

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.headline)
                    .frame(width: 34, height: 34)

                Text("图传刷新频率")
                    .font(.headline)

                Spacer()

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.subheadline.bold())
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("关闭")
            }

            Text(selectedOption.title)
                .font(.system(size: 42, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(value: selectedIndex))
                .animation(.snappy(duration: 0.2), value: safeIndex)

            VStack(spacing: 8) {
                Slider(
                    value: sliderBinding,
                    in: 0 ... Double(options.count - 1),
                    step: 1,
                    onEditingChanged: { isEditing in
                        if !isEditing {
                            onValueChanged(selectedOption)
                        }
                    }
                )
                .tint(.orange)

                HStack {
                    Text(options.first?.title ?? "--")
                    Spacer()
                    Text(options.last?.title ?? "--")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            Text("画面的拉取间隔，不代表实际帧率。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(22)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 30))
        .shadow(color: .black.opacity(0.28), radius: 32, y: 18)
        .accessibilityElement(children: .contain)
    }

    private var sliderBinding: Binding<Double> {
        Binding(
            get: { selectedIndex },
            set: { selectedIndex = $0 }
        )
    }
}

private enum CaptureKeyStyle {
    case rail
    case tile

    var minHeight: CGFloat {
        switch self {
        case .rail: return 40
        case .tile: return 56
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
    var isAutoLocked = false
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    Text(title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)

                    Spacer(minLength: 0)

                    if isBusy {
                        ProgressView()
                            .controlSize(.mini)
                    }

                    if isAutoLocked {
                        CaptureAutoBadge()
                    }
                }

                Text(value)
                    .font(.headline.monospacedDigit().weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.52)
            }
            .frame(maxWidth: .infinity, minHeight: style.minHeight, alignment: .leading)
            .padding(10)
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
        .accessibilityLabel("\(title)，\(value)" + (isAutoLocked ? "，自动" : ""))
    }
}

private struct CaptureSliderEditor: View {
    let parameter: CaptureParameter
    let options: [CaptureOption]
    @Binding var selectedIndex: Double
    let isAutoLocked: Bool
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

                VStack(alignment: .leading, spacing: 2) {
                    Text(parameter.title)
                        .font(.headline)
                }

                Spacer()

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.subheadline.bold())
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("关闭")
            }

            HStack(spacing: 10) {
                Text(selectedOption.title)
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .contentTransition(.numericText(value: selectedIndex))

                if isAutoLocked {
                    CaptureAutoBadge()
                }
            }
            .animation(.snappy(duration: 0.2), value: safeIndex)

            if parameter.usesPresetSelection {
                ScrollView(.vertical) {
                    presetOptionsView
                        .padding(2)
                }
                .frame(maxHeight: 220)
                .disabled(isAutoLocked)
            } else {
                VStack(spacing: 8) {
                    Slider(
                        value: sliderBinding,
                        in: 0 ... Double(max(options.count - 1, 1)),
                        step: 1,
                        onEditingChanged: { isEditing in
                            if !isEditing {
                                onValueChanged(selectedOption.rawValue)
                            }
                        }
                    )
                    .tint(.orange)
                    .disabled(isAutoLocked)

                    HStack {
                        Text(options.first?.title ?? "--")
                        Spacer()
                        Text(options.last?.title ?? "--")
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
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
            }
        )
    }

    private func isSelected(_ option: CaptureOption) -> Bool {
        option.rawValue == selectedOption.rawValue
    }

    @ViewBuilder
    private var presetOptionsView: some View {
        if parameter == .focusMode {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                spacing: 10
            ) {
                ForEach(options) { option in
                    presetOptionButton(option)
                }
            }
        } else if parameter == .exposureMode {
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    ForEach(options.prefix(2)) { option in
                        presetOptionButton(option, isCircular: true)
                    }
                }

                GridRow {
                    ForEach(options.dropFirst(2).prefix(2)) { option in
                        presetOptionButton(option, isCircular: true)
                    }
                }

                if options.count > 4 {
                    GridRow {
                        presetOptionButton(options[4], isCircular: true)
                    }
                }
            }
        } else {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 120), spacing: 10)],
                spacing: 10
            ) {
                ForEach(options) { option in
                    presetOptionButton(option)
                }
            }
        }
    }

    @ViewBuilder
    private func presetOptionButton(
        _ option: CaptureOption,
        isCircular: Bool = false
    ) -> some View {
        if isSelected(option) {
            presetOptionButtonBase(option, isCircular: isCircular)
                .buttonStyle(.glassProminent)
        } else {
            presetOptionButtonBase(option, isCircular: isCircular)
                .buttonStyle(.glass)
        }
    }

    private func presetOptionButtonBase(
        _ option: CaptureOption,
        isCircular: Bool
    ) -> some View {
        Button {
            selectedIndex = Double(options.firstIndex(of: option) ?? 0)
            onValueChanged(option.rawValue)
        } label: {
            Text(option.title)
                .font(.body.weight(.semibold))
                .foregroundStyle(optionTextColor(for: option))
                .frame(
                    maxWidth: isCircular ? nil : .infinity,
                    minHeight: isCircular ? 52 : 42
                )
                .frame(width: isCircular ? 52 : nil)
        }
        .clipShape(
            isCircular
                ? AnyShape(Circle())
                : AnyShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        )
        .contentShape(
            isCircular
                ? AnyShape(Circle())
                : AnyShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        )
        .accessibilityLabel(option.title)
    }

    private func optionTextColor(for option: CaptureOption) -> Color {
        if isSelected(option) {
            return .white
        }
        if parameter == .exposureMode, option.title == "AUTO" {
            return .green
        }
        return .primary
    }
}

private struct CaptureAutoBadge: View {
    var body: some View {
        Text("AUTO")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.blue, in: Capsule())
            .fixedSize()
            .accessibilityLabel("自动")
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

private struct CaptureLiveViewStatusBar: View {
    @EnvironmentObject private var camera: CameraConnectionService

    private var connectionTitle: String {
        switch camera.state {
        case .connected where camera.liveViewImage != nil:
            return "实时"
        case .connected where camera.isLiveViewActive:
            return "启动中"
        case .connected:
            return camera.liveViewError == nil ? "等待图传" : "不可用"
        case .connecting:
            return "连接中"
        default:
            return "未连接"
        }
    }

    private var connectionColor: Color {
        switch camera.state {
        case .connected where camera.liveViewImage != nil:
            return .green
        case .connected where camera.isLiveViewActive:
            return .yellow
        case .connected:
            return camera.liveViewError == nil ? .yellow : .orange
        case .connecting:
            return .yellow
        default:
            return .gray
        }
    }

    private var frameRateText: String {
        guard let frameRate = camera.liveViewFrameRate else { return "--" }
        return String(format: "%.1f", frameRate)
    }

    private var batteryText: String {
        guard case .connected = camera.state,
              let batteryLevel = camera.cameraStatus.batteryLevel
        else { return "--%" }
        return "\(batteryLevel)%"
    }

    private var exposureModeText: String {
        CaptureOptionCatalog.displayedValue(
            for: .exposureMode,
            rawValue: camera.captureParameters[.exposureMode]
        )
    }

    var body: some View {
        HStack(spacing: 18) {
            HStack(spacing: 6) {
                Circle()
                    .fill(connectionColor)
                    .frame(width: 8, height: 8)
                Text(connectionTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
            }

            Spacer(minLength: 12)

            HStack(spacing: 16) {
                CaptureLiveViewMetric(title: "模式", value: exposureModeText)
                CaptureLiveViewMetric(title: "帧率", value: frameRateText)
                CaptureLiveViewMetric(title: "电量", value: batteryText)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
    }
}

private struct CaptureLiveViewMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.weight(.bold))
                .fontDesign(.rounded)
                .foregroundStyle(.primary)
        }
    }
}

private struct CaptureExposureScale: View {
    let rawValue: UInt64?
    let options: [CaptureOption]
    let onCommit: (UInt64) -> Void

    @State private var selectedIndex = 0.0
    @State private var isDragging = false

    private var currentIndex: Double {
        guard let rawValue,
              let index = options.firstIndex(where: { $0.rawValue == rawValue })
        else {
            return selectedIndex
        }
        return Double(index)
    }

    private var selectedOption: CaptureOption {
        let index = min(max(Int(selectedIndex.rounded()), 0), options.count - 1)
        return options[index]
    }

    var body: some View {
        if !options.isEmpty {
            GeometryReader { proxy in
                let trackTop: CGFloat = 4
                let trackBottom = trackTop + max(1, proxy.size.height - 42)
                let trackHeight = trackBottom - trackTop
                let knobY = trackTop + CGFloat(1 - selectedIndex / Double(max(options.count - 1, 1))) * trackHeight

                ZStack(alignment: .topLeading) {
                    Path { path in
                        path.move(to: CGPoint(x: 45, y: trackTop))
                        path.addLine(to: CGPoint(x: 45, y: trackBottom))
                    }
                    .stroke(.white.opacity(0.86), style: StrokeStyle(lineWidth: 2, lineCap: .round))

                    ForEach(0..<9, id: \.self) { tick in
                        let fraction = Double(tick) / 8
                        let optionIndex = Int(
                            (Double(options.count - 1) * (1 - fraction)).rounded()
                        )
                        let y = trackTop + CGFloat(fraction) * trackHeight
                        let isMajor = tick.isMultiple(of: 2)
                        Capsule()
                            .fill(.white.opacity(isMajor ? 0.9 : 0.58))
                            .frame(width: isMajor ? 13.5 : 6.75, height: isMajor ? 2 : 1)
                            .position(x: isMajor ? 38 : 41.5, y: y)

                        if isMajor {
                            Text(options[optionIndex].title)
                                .font(.caption2.monospacedDigit().weight(.medium))
                                .foregroundStyle(.white.opacity(0.92))
                                .lineLimit(1)
                                .minimumScaleFactor(0.65)
                                .frame(width: 36, alignment: .trailing)
                                .position(x: 9, y: y)
                        }
                    }

                    Circle()
                        .fill(.orange)
                        .frame(width: 6, height: 6)
                        .position(x: 45, y: knobY)

                    Text(selectedOption.title)
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 64)
                        .position(x: 31, y: trackBottom + 18)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isDragging = true
                            let fraction = min(max((value.location.y - trackTop) / trackHeight, 0), 1)
                            selectedIndex = Double(options.count - 1) * Double(1 - fraction)
                        }
                        .onEnded { _ in
                            selectedIndex = selectedIndex.rounded()
                            isDragging = false
                            onCommit(selectedOption.rawValue)
                        }
                )
                .onAppear {
                    selectedIndex = currentIndex
                }
                .onChange(of: rawValue) { _, _ in
                    if !isDragging {
                        selectedIndex = currentIndex
                    }
                }
                .onChange(of: options) { _, _ in
                    if !isDragging {
                        selectedIndex = currentIndex
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("曝光补偿")
                .accessibilityValue(selectedOption.title)
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment:
                        selectedIndex = min(selectedIndex.rounded() + 1, Double(options.count - 1))
                    case .decrement:
                        selectedIndex = max(selectedIndex.rounded() - 1, 0)
                    @unknown default:
                        break
                    }
                    onCommit(selectedOption.rawValue)
                }
            }
            .frame(minHeight: 80)
        }
    }
}

#Preview {
    CaptureView()
        .environmentObject(CameraConnectionService())
}
