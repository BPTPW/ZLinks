//
//  GalleryView.swift
//  ZLinks
//

import SwiftUI
import UIKit

struct GalleryView: View {
    @EnvironmentObject private var camera: CameraConnectionService

    @State private var isRefreshing = false
    @State private var loadError: String?
    @State private var thumbnailImages: [UInt32: UIImage] = [:]
    @State private var failedThumbnails: Set<UInt32> = []
    @State private var visibleHandles: Set<UInt32> = []
    @State private var isThumbnailPumpRunning = false
    @State private var selectedDirectoryID: UInt32?
    @State private var isDirectorySwitching = false
    @State private var selectedItem: CameraConnectionService.GalleryItem?
    @Namespace private var galleryTransition

    private let spacing: CGFloat = 3
    private let cornerRadius: CGFloat = 6
    private let columns = Array(
        repeating: GridItem(.flexible(minimum: 0), spacing: 3),
        count: 4
    )

    var body: some View {
        NavigationStack {
            Group {
                switch camera.state {
                case .connected:
                    connectedContent
                case .connecting:
                    statusPlaceholder(
                        title: "正在连接相机",
                        systemImage: "wifi",
                        message: "连接完成后可浏览相机存储中的照片与视频。"
                    )
                default:
                    statusPlaceholder(
                        title: "未连接相机",
                        systemImage: "photo.on.rectangle.angled",
                        message: "请先在“我的相机”中连接 Nikon 相机，再刷新图库。"
                    )
                }
            }
            .navigationTitle("图库")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    directoryPicker
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await reloadGallery(force: true) }
                    } label: {
                        if isRefreshing && !isDirectorySwitching {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.body.weight(.semibold))
                        }
                    }
                    .disabled(!isConnected || isRefreshing || isDirectorySwitching)
                    .accessibilityLabel("刷新图库")
                }
            }
            .task(id: connectionTaskID) {
                await reloadGallery(force: false)
            }
            .onChange(of: camera.selectedGalleryDirectoryID) { _, newValue in
                if selectedDirectoryID != newValue {
                    selectedDirectoryID = newValue
                }
            }
            .navigationDestination(item: $selectedItem) { item in
                GalleryPreviewView(
                    item: item,
                    thumbnail: thumbnailImages[item.handle],
                    camera: camera
                )
                .toolbar(.hidden, for: .navigationBar)
                .toolbar(.hidden, for: .tabBar)
                .navigationTransition(.zoom(sourceID: item.handle, in: galleryTransition))
            }
        }
    }

    @ViewBuilder
    private var directoryPicker: some View {
        if isConnected, !camera.galleryDirectories.isEmpty {
            Picker(
                "目录",
                selection: Binding(
                    get: { selectedDirectoryID ?? camera.selectedGalleryDirectoryID },
                    set: { newValue in
                        guard let newValue else { return }
                        guard newValue != selectedDirectoryID else { return }
                        selectedDirectoryID = newValue
                        Task { await switchDirectory(to: newValue) }
                    }
                )
            ) {
                ForEach(camera.galleryDirectories) { directory in
                    Text(directory.pickerTitle)
                        .tag(Optional(directory.id))
                }
            }
            .pickerStyle(.menu)
            .tint(.primary)
            .disabled(isRefreshing || isDirectorySwitching)
            .accessibilityLabel("选择图库目录")
        } else if isConnected, isRefreshing {
            ProgressView()
                .controlSize(.small)
        } else {
            Text("图库")
                .font(.headline)
        }
    }

    private var isConnected: Bool {
        if case .connected = camera.state {
            return true
        }
        return false
    }

    private var connectionTaskID: String {
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

    @ViewBuilder
    private var connectedContent: some View {
        if (isRefreshing || isDirectorySwitching) && camera.galleryItems.isEmpty {
            ProgressView(isDirectorySwitching ? "正在切换目录…" : "正在读取图库…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError, camera.galleryItems.isEmpty {
            statusPlaceholder(
                title: "图库读取失败",
                systemImage: "exclamationmark.triangle",
                message: loadError
            )
        } else if camera.galleryDirectories.isEmpty {
            statusPlaceholder(
                title: "暂无目录",
                systemImage: "folder",
                message: "相机存储中没有可浏览的目录。"
            )
        } else if camera.galleryItems.isEmpty {
            statusPlaceholder(
                title: "暂无媒体",
                systemImage: "photo",
                message: "当前目录没有可显示的照片或视频。"
            )
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: spacing) {
                    ForEach(camera.galleryItems) { item in
                        GalleryThumbnailCell(
                            item: item,
                            image: thumbnailImages[item.handle],
                            cornerRadius: cornerRadius,
                            hasFailed: failedThumbnails.contains(item.handle)
                        )
                        .frame(maxWidth: .infinity)
                        .aspectRatio(1, contentMode: .fit)
                        .clipped()
                        .contentShape(Rectangle())
                        .matchedTransitionSource(id: item.handle, in: galleryTransition)
                        .onTapGesture {
                            selectedItem = item
                        }
                        .onAppear {
                            handleCellAppear(item)
                        }
                        .onDisappear {
                            handleCellDisappear(item)
                        }
                    }
                }
                .padding(.horizontal, spacing)
                .padding(.top, spacing)
                .padding(.bottom, 24)
            }
            .refreshable {
                await reloadGallery(force: true)
            }
        }
    }

    private func statusPlaceholder(title: String, systemImage: String, message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @MainActor
    private func reloadGallery(force: Bool) async {
        guard isConnected else {
            thumbnailImages = [:]
            failedThumbnails = []
            visibleHandles = []
            selectedDirectoryID = nil
            loadError = nil
            return
        }

        if !force, !camera.galleryItems.isEmpty, !camera.galleryDirectories.isEmpty {
            selectedDirectoryID = camera.selectedGalleryDirectoryID
            return
        }

        isRefreshing = true
        loadError = nil
        defer { isRefreshing = false }

        thumbnailImages = [:]
        failedThumbnails = []
        visibleHandles = []

        await camera.refreshGallery(selectingDirectoryID: selectedDirectoryID)
        selectedDirectoryID = camera.selectedGalleryDirectoryID

        if camera.galleryDirectories.isEmpty {
            loadError = nil
        }

        await pumpVisibleThumbnails()
    }

    @MainActor
    private func switchDirectory(to directoryID: UInt32) async {
        guard isConnected else { return }
        guard !isDirectorySwitching else { return }

        isDirectorySwitching = true
        loadError = nil
        defer { isDirectorySwitching = false }

        // Clear UI immediately on switch.
        thumbnailImages = [:]
        failedThumbnails = []
        visibleHandles = []

        await camera.selectGalleryDirectory(id: directoryID)
        selectedDirectoryID = camera.selectedGalleryDirectoryID
        await pumpVisibleThumbnails()
    }

    @MainActor
    private func handleCellAppear(_ item: CameraConnectionService.GalleryItem) {
        visibleHandles.insert(item.handle)
        Task { await pumpVisibleThumbnails() }
    }

    @MainActor
    private func handleCellDisappear(_ item: CameraConnectionService.GalleryItem) {
        visibleHandles.remove(item.handle)
    }

    @MainActor
    private func pumpVisibleThumbnails() async {
        guard isConnected else { return }
        guard !isThumbnailPumpRunning else { return }

        isThumbnailPumpRunning = true
        defer { isThumbnailPumpRunning = false }

        while isConnected {
            guard let item = nextVisibleItemNeedingWork() else {
                await Task.yield()
                if nextVisibleItemNeedingWork() == nil {
                    break
                }
                continue
            }

            if item.isVideo, item.durationSeconds == nil {
                guard visibleHandles.contains(item.handle) else { continue }
                _ = await camera.videoDurationSeconds(for: item.handle)
            }

            if thumbnailImages[item.handle] != nil || failedThumbnails.contains(item.handle) {
                continue
            }

            guard visibleHandles.contains(item.handle) else { continue }

            if let image = await camera.thumbnailImage(for: item.handle) {
                thumbnailImages[item.handle] = image
            } else if visibleHandles.contains(item.handle) {
                failedThumbnails.insert(item.handle)
            }
        }
    }

    @MainActor
    private func nextVisibleItemNeedingWork() -> CameraConnectionService.GalleryItem? {
        for item in camera.galleryItems where visibleHandles.contains(item.handle) {
            let needsDuration = item.isVideo && item.durationSeconds == nil
            let needsThumb =
                thumbnailImages[item.handle] == nil
                && !failedThumbnails.contains(item.handle)
            if needsDuration || needsThumb {
                return item
            }
        }
        return nil
    }
}


private struct GalleryPreviewView: View {
    let item: CameraConnectionService.GalleryItem
    let thumbnail: UIImage?
    let camera: CameraConnectionService

    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var isLoading = false
    @State private var hasLoadFailed = false
    @State private var scale: CGFloat = 1
    @State private var settledScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var settledOffset: CGSize = .zero
    @State private var controlsVisible = true
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                (isImmersive ? Color.black : Color(uiColor: .systemBackground))
                    .ignoresSafeArea()
                    .animation(.easeInOut(duration: 0.2), value: isImmersive)

                previewImage
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .scaleEffect(scale)
                    .offset(x: offset.width, y: offset.height + dragOffset)
                    .contentShape(Rectangle())
                    .gesture(dragGesture)
                    .gesture(magnificationGesture)
                    .onTapGesture(count: 2) { resetZoom() }
                    .onTapGesture(count: 1) { toggleControls() }

                if controlsVisible {
                    VStack {
                        HStack {
                            Button { dismiss() } label: {
                                Image(systemName: "chevron.left")
                                    .font(.title3.weight(.semibold))
                                    .frame(width: 44, height: 44)
                                    .background(.ultraThinMaterial, in: Circle())
                            }
                            .accessibilityLabel("返回图库")
                            Spacer()
                            Text(item.filename)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                                .padding(.horizontal, 12)
                        }
                        .foregroundStyle(isImmersive ? .white : .primary)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        Spacer()
                    }
                    .transition(.opacity)
                }

                if isLoading {
                    ProgressView()
                        .tint(isImmersive ? .white : nil)
                } else if hasLoadFailed && image == nil {
                    VStack(spacing: 10) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.largeTitle)
                        Text("无法加载原图")
                            .font(.subheadline)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .statusBarHidden(isImmersive)
            .onAppear { loadFullImage() }
            .animation(.easeInOut(duration: 0.2), value: controlsVisible)
            .animation(.interactiveSpring(response: 0.28, dampingFraction: 0.82), value: dragOffset)
            .onChange(of: proxy.size) { _, _ in clampOffset() }
        }
    }

    private var isImmersive: Bool { scale > 1.01 || !controlsVisible }

    @ViewBuilder
    private var previewImage: some View {
        if let image = image ?? thumbnail {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .overlay(alignment: .center) {
                    if isLoading { Color.clear }
                }
        } else {
            Color.clear
        }
    }

    private var magnificationGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = min(max(settledScale * value.magnification, 1), 5)
                if scale > 1.01 {
                    controlsVisible = false
                }
            }
            .onEnded { _ in
                settledScale = scale
                if scale == 1 { settledOffset = .zero; offset = .zero }
            }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                if scale > 1.01 {
                    offset = CGSize(width: settledOffset.width + value.translation.width, height: settledOffset.height + value.translation.height)
                } else if abs(value.translation.height) > abs(value.translation.width) {
                    dragOffset = value.translation.height
                }
            }
            .onEnded { value in
                if scale > 1.01 {
                    settledOffset = offset
                } else if value.translation.height > 120 || value.predictedEndTranslation.height > 240 {
                    dismiss()
                } else {
                    dragOffset = 0
                }
            }
    }

    private func loadFullImage() {
        guard !item.isVideo, image == nil, !isLoading else { return }
        isLoading = true
        Task {
            let loaded = await camera.objectImage(for: item.handle)
            await MainActor.run {
                image = loaded
                hasLoadFailed = loaded == nil
                isLoading = false
            }
        }
    }

    private func toggleControls() {
        withAnimation { controlsVisible.toggle() }
    }

    private func resetZoom() {
        withAnimation(.interactiveSpring(response: 0.28, dampingFraction: 0.82)) {
            scale = 1
            settledScale = 1
            offset = .zero
            settledOffset = .zero
            controlsVisible = true
        }
    }

    private func clampOffset() {
        if scale <= 1.01 { offset = .zero; settledOffset = .zero }
    }
}

private struct GalleryThumbnailCell: View {
    let item: CameraConnectionService.GalleryItem
    let image: UIImage?
    let cornerRadius: CGFloat
    let hasFailed: Bool

    var body: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.12))
            .overlay {
                ZStack {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                            .clipped()
                    } else if hasFailed {
                        Image(systemName: item.isVideo ? "video" : "photo")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                if item.isVideo {
                    Text(Self.durationText(for: item.durationSeconds))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.55), in: Capsule())
                        .padding(5)
                }
            }
            .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        if item.isVideo {
            return "视频 \(item.filename) \(Self.durationText(for: item.durationSeconds))"
        }
        return "照片 \(item.filename)"
    }

    private static func durationText(for seconds: Int?) -> String {
        let total = max(seconds ?? 0, 0)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }
}

#Preview {
    GalleryView()
        .environmentObject(CameraConnectionService())
}
