//
//  GalleryView.swift
//  ZLinks
//

import Photos
import SwiftUI
import UIKit
import UniformTypeIdentifiers

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
    @State private var isSelectionMode = false
    @State private var selectedHandles: Set<UInt32> = []
    @State private var isTransferPresented = false
    @State private var transferItems: [GalleryDownload] = []
    @State private var transferRequiresConfirmation = false
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
                    if isSelectionMode {
                        Button { exitSelectionMode() } label: { Image(systemName: "xmark") }
                            .accessibilityLabel("取消多选")
                    } else {
                        HStack(spacing: 26) {
                            Button { enterSelectionMode() } label: { Image(systemName: "checkmark.circle") }
                            Button { Task { await reloadGallery(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                                .disabled(!isConnected || isRefreshing || isDirectorySwitching)
                        }
                        .padding(.horizontal, 5)
                    }
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
            .toolbar(isSelectionMode ? .hidden : .automatic, for: .tabBar)
            .safeAreaInset(edge: .bottom) {
                if isSelectionMode { selectionToolbar }
            }
            .sheet(isPresented: $isTransferPresented) {
                TransferSheet(
                    items: transferItems,
                    camera: camera,
                    requiresConfirmation: transferRequiresConfirmation
                )
                .id(transferItems.map { "\($0.handle)-\($0.format.rawValue)" }.joined(separator: ","))
            }
            .navigationDestination(item: $selectedItem) { item in
                GalleryPreviewView(
                    item: item,
                    thumbnail: thumbnailImages[item.handle],
                    camera: camera,
                    onDownload: { format in
                        startTransfer(item: item, format: format)
                    }
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
                            hasFailed: failedThumbnails.contains(item.handle),
                            isSelected: selectedHandles.contains(item.handle),
                            selectionMode: isSelectionMode
                        )
                        .frame(maxWidth: .infinity)
                        .aspectRatio(1, contentMode: .fit)
                        .clipped()
                        .contentShape(Rectangle())
                        .matchedTransitionSource(id: item.handle, in: galleryTransition)
                        .onTapGesture {
                            if isSelectionMode {
                                if item.isVideo { return }
                                if selectedHandles.contains(item.handle) { selectedHandles.remove(item.handle) } else { selectedHandles.insert(item.handle) }
                            } else { selectedItem = item }
                        }
                        .contextMenu {
                            if !item.isVideo {
                                Button { enterSelectionMode(selecting: item.handle) } label: {
                                    Label("多选", systemImage: "checkmark.circle")
                                }
                            }
                            if let format = item.photoFormat {
                                if format.supportsRAW {
                                    Button {
                                        startTransfer(item: item, format: .raw)
                                    } label: {
                                        Label("下载 RAW", systemImage: "r.square")
                                    }
                                }
                                if format.supportsJPEG {
                                    Button {
                                        startTransfer(item: item, format: .jpeg)
                                    } label: {
                                        Label("下载 JPEG", systemImage: "j.square")
                                    }
                                }
                            }
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

    private var selectionToolbar: some View {
        HStack {
            Menu {
                ForEach(multiDownloadOptions) { option in
                    Button {
                        startMultiTransfer(option)
                    } label: {
                        Label(option.title, systemImage: option.symbol)
                    }
                }
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .frame(width: 42, height: 42)
            .glassEffect(.regular.interactive(), in: .circle)
            .disabled(multiDownloadOptions.isEmpty)
            Spacer()
        }
        .padding(.horizontal, 20).frame(maxWidth: .infinity).frame(height: 49)
        .background(.bar)
    }

    private func enterSelectionMode(selecting handle: UInt32? = nil) {
        isSelectionMode = true
        if let handle { selectedHandles.insert(handle) }
    }

    private func exitSelectionMode() { isSelectionMode = false; selectedHandles.removeAll() }
    private var selectedPhotoItems: [CameraConnectionService.GalleryItem] {
        camera.galleryItems.filter { selectedHandles.contains($0.handle) && !$0.isVideo }
    }

    private var multiDownloadOptions: [MultiDownloadOption] {
        let items = selectedPhotoItems
        guard !items.isEmpty else { return [] }

        let jpegCount = items.filter { $0.photoFormat?.supportsJPEG == true }.count
        let rawCount = items.filter { $0.photoFormat?.supportsRAW == true }.count
        var options: [MultiDownloadOption] = []

        if jpegCount == items.count {
            options.append(.jpeg)
        } else if jpegCount > 0 {
            options.append(.preferredJPEG)
        }

        if rawCount == items.count {
            options.append(.raw)
        } else if rawCount > 0 {
            options.append(.preferredRAW)
        }

        return options
    }

    private func startMultiTransfer(_ option: MultiDownloadOption) {
        let downloads = selectedPhotoItems.compactMap {
            makeDownload(for: $0, format: option.format, fallbackToOtherFormat: option.isPreferred)
        }
        startTransfer(downloads: downloads, requiresConfirmation: true)
    }

    private func startTransfer(item: CameraConnectionService.GalleryItem, format: GalleryDownloadFormat) {
        guard let download = makeDownload(for: item, format: format, fallbackToOtherFormat: false) else {
            return
        }
        startTransfer(downloads: [download], requiresConfirmation: false)
    }

    private func makeDownload(
        for item: CameraConnectionService.GalleryItem,
        format: GalleryDownloadFormat,
        fallbackToOtherFormat: Bool
    ) -> GalleryDownload? {
        var requestedFormat = format
        if requestedFormat == .raw && item.rawHandle == nil {
            guard fallbackToOtherFormat, item.jpegHandle != nil else { return nil }
            requestedFormat = .jpeg
        } else if requestedFormat == .jpeg && item.jpegHandle == nil {
            guard fallbackToOtherFormat, item.rawHandle != nil else { return nil }
            requestedFormat = .raw
        }

        let handle: UInt32
        let filename: String
        let fileSize: UInt64
        switch requestedFormat {
        case .raw:
            guard let rawHandle = item.rawHandle, let rawFilename = item.rawFilename else { return nil }
            handle = rawHandle
            filename = rawFilename
            fileSize = item.rawFileSize ?? 0
        case .jpeg:
            guard let jpegHandle = item.jpegHandle, let jpegFilename = item.jpegFilename else { return nil }
            handle = jpegHandle
            filename = jpegFilename
            fileSize = item.jpegFileSize ?? 0
        }

        return GalleryDownload(
            handle: handle,
            filename: filename,
            fileSize: fileSize,
            format: requestedFormat
        )
    }

    private func startTransfer(downloads: [GalleryDownload], requiresConfirmation: Bool) {
        guard !downloads.isEmpty else { return }
        transferItems = downloads
        transferRequiresConfirmation = requiresConfirmation
        isTransferPresented = false
        DispatchQueue.main.async { isTransferPresented = true }
        exitSelectionMode()
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

            if let image = await camera.thumbnailImage(for: item.thumbnailHandle) {
                withAnimation(.easeIn(duration: 0.28)) {
                    thumbnailImages[item.handle] = image
                }
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

private enum GalleryDownloadFormat: String, Hashable {
    case raw
    case jpeg
}

private struct GalleryDownload: Identifiable, Hashable {
    let handle: UInt32
    let filename: String
    let fileSize: UInt64
    let format: GalleryDownloadFormat

    var id: String {
        "\(handle)-\(format.rawValue)"
    }
}

private enum MultiDownloadOption: String, Identifiable {
    case jpeg
    case preferredJPEG
    case raw
    case preferredRAW

    var id: String { rawValue }

    var format: GalleryDownloadFormat {
        switch self {
        case .jpeg, .preferredJPEG: return .jpeg
        case .raw, .preferredRAW: return .raw
        }
    }

    var isPreferred: Bool {
        self == .preferredJPEG || self == .preferredRAW
    }

    var title: String {
        switch self {
        case .jpeg: return "下载 JPEG"
        case .preferredJPEG: return "优先下载 JPEG"
        case .raw: return "下载 RAW"
        case .preferredRAW: return "优先下载 RAW"
        }
    }

    var symbol: String {
        switch self {
        case .jpeg, .preferredJPEG: return "j.square"
        case .raw, .preferredRAW: return "r.square"
        }
    }
}

private struct GalleryPreviewView: View {
    let item: CameraConnectionService.GalleryItem
    let thumbnail: UIImage?
    let camera: CameraConnectionService
    let onDownload: (GalleryDownloadFormat) -> Void

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
                        ZStack(alignment: .top) {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Button { dismiss() } label: {
                                        Image(systemName: "chevron.left")
                                            .font(.title3.weight(.semibold))
                                            .frame(width: 32, height: 32)
                                            .foregroundStyle(.primary)
                                    }
                                    .buttonStyle(.plain)
                                    .frame(width: 42, height: 42)
                                    .glassEffect(.regular.interactive(), in: .circle)
                                    .accessibilityLabel("返回图库")

                                    if let format = item.photoFormat {
                                        Text(format.title)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.primary)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 5)
                                            .glassEffect(.regular, in: .capsule)
                                    }
                                }
                                Spacer()
                            }
                            captureTimestampView
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        Spacer()
                        HStack {
                            if let format = item.photoFormat {
                                Menu {
                                    if format.supportsRAW {
                                        Button { onDownload(.raw) } label: {
                                            Label("下载 RAW", systemImage: "r.square")
                                        }
                                    }
                                    if format.supportsJPEG {
                                        Button { onDownload(.jpeg) } label: {
                                            Label("下载 JPEG", systemImage: "j.square")
                                        }
                                    }
                                } label: {
                                    Image(systemName: "square.and.arrow.down")
                                        .foregroundStyle(.primary)
                                }
                                .buttonStyle(.plain)
                                .frame(width: 42, height: 42)
                                .glassEffect(.regular.interactive(), in: .circle)
                            }
                            Spacer()
                        }.padding(.horizontal, 16).padding(.bottom, 12)
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
    private var captureTimestampView: some View {
        if let captureDateParts {
            VStack() {
                Text(captureDateParts.date)
                    .font(.caption.weight(.semibold))
                    
                Text(captureDateParts.time)
                    .font(.caption)
            }
            .fontDesign(.rounded)
            .foregroundStyle(isImmersive ? .white : .primary)
            .padding(.horizontal, 22)
            .padding(.vertical, 7)
            .glassEffect(.regular, in: .capsule)
            .allowsHitTesting(false)
        }
    }

    private var captureDateParts: (date: String, time: String)? {
        guard let captureDate = item.captureDate else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        let currentYear = calendar.component(.year, from: .now)
        let captureYear = calendar.component(.year, from: captureDate)

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "zh_CN")
        dateFormatter.calendar = calendar
        dateFormatter.timeZone = .autoupdatingCurrent
        dateFormatter.dateFormat = captureYear == currentYear ? "MM月dd日" : "yyyy年MM月dd日"

        let timeFormatter = DateFormatter()
        timeFormatter.locale = chineseTimeLocale
        timeFormatter.calendar = Calendar.autoupdatingCurrent
        timeFormatter.timeZone = .autoupdatingCurrent
        timeFormatter.dateStyle = .none
        timeFormatter.timeStyle = .short

        return (
            dateFormatter.string(from: captureDate),
            timeFormatter.string(from: captureDate)
        )
    }

    private var chineseTimeLocale: Locale {
        let hourCycle = Locale.autoupdatingCurrent.hourCycle
        let hourCycleOverride: String

        switch hourCycle {
        case .oneToTwelve:
            hourCycleOverride = "h12"
        case .oneToTwentyFour, .zeroToTwentyThree:
            hourCycleOverride = "h23"
        @unknown default:
            hourCycleOverride = "h23"
        }

        return Locale(identifier: "zh-Hans-CN@hours=\(hourCycleOverride)")
    }


    @ViewBuilder
    private var previewImage: some View {
        if let image {
            renderedImage(image)
                .transition(.opacity)
        } else if let thumbnail {
            renderedImage(thumbnail)
        } else {
            Color.clear
        }
    }

    private func renderedImage(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .allowedDynamicRange(.high)
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
            let loaded = await camera.objectImage(for: item.previewHandle)
            await MainActor.run {
                withAnimation(.easeIn(duration: 0.28)) {
                    image = loaded
                    hasLoadFailed = loaded == nil
                    isLoading = false
                }
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
    let isSelected: Bool
    let selectionMode: Bool

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
                            .transition(.opacity)
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
            .overlay(alignment: .topLeading) {
                if let format = item.photoFormat, let symbol = format.thumbnailSymbol {
                    Image(systemName: symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(format == .raw ? .orange : .white)
                        .padding(5)
                }
            }
            .overlay { if selectionMode && isSelected { Color.white.opacity(0.42); Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.blue).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(6) } }
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
        let format = item.photoFormat?.title ?? "照片"
        return "\(format) \(item.filename)"
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

private struct TransferSheet: View {
    let items: [GalleryDownload]
    let camera: CameraConnectionService
    let requiresConfirmation: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .confirm
    @State private var current = 0
    @State private var received = 0
    @State private var failed = 0
    @State private var cancelled = 0
    @State private var bytesReceived: UInt64 = 0
    @State private var totalBytes: UInt64 = 0
    @State private var currentName = ""
    @State private var transferTask: Task<Void, Never>?
    @State private var showCancelConfirmation = false
    enum Phase { case confirm, transferring, completed }
    init(items: [GalleryDownload], camera: CameraConnectionService, requiresConfirmation: Bool) {
        self.items = items
        self.camera = camera
        self.requiresConfirmation = requiresConfirmation
        _phase = State(initialValue: requiresConfirmation ? .confirm : .transferring)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                if phase == .confirm { Text("保存 \(items.count) 张图片到相册").font(.headline); Spacer(); Button("确认") { begin() }.buttonStyle(.borderedProminent); Button("取消") { dismiss() } }
                else if phase == .transferring { transferringView }
                else {
                    Text("成功接收\(received)个文件 失败\(failed)个\(cancelled > 0 ? " 取消传输\(cancelled)个" : "")")
                        .multilineTextAlignment(.center); Spacer(); Button("完成") {
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
            .navigationTitle(phase == .transferring ? "传输中" : phase == .completed ? "传输完成" : "确认下载").navigationBarTitleDisplayMode(.inline)
        }.presentationDetents([.height(250)]).interactiveDismissDisabled(phase == .transferring)
            .onAppear { if phase == .transferring && transferTask == nil { begin() } }
            .onDisappear { transferTask?.cancel() }
    }

    private var progress: Double { totalBytes > 0 ? min(Double(bytesReceived) / Double(totalBytes), 1) : (items.isEmpty ? 0 : Double(current) / Double(items.count)) }
    private var transferringView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("已接收 \(received)/\(items.count)"); Spacer(); Text("\(Int(progress * 100))%") }
            ProgressView(value: progress)
            HStack { Text("正在接收 \(currentName)").lineLimit(1); Spacer(); Text("处理中") }.font(.caption)
            Spacer()
            HStack { Spacer(); Button("取消") { showCancelConfirmation = true } }
                .confirmationDialog("取消传输？", isPresented: $showCancelConfirmation) {
                    Button("取消传输", role: .destructive) { transferTask?.cancel(); cancelled = max(items.count - current, 0); phase = .completed }
                    Button("继续传输", role: .cancel) {}
                }
        }
    }

    private func begin() {
        phase = .transferring; current = 0; totalBytes = items.reduce(0) { $0 + $1.fileSize }
        transferTask = Task { @MainActor in
            let auth = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard auth == .authorized || auth == .limited else { failed = items.count; phase = .completed; return }
            for (index, item) in items.enumerated() {
                if Task.isCancelled { cancelled = items.count - index; break }
                current = index; currentName = item.filename
                guard let data = await camera.objectData(for: item.handle) else { failed += 1; continue }
                bytesReceived += UInt64(data.count)
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + item.filename)
                do { try data.write(to: url, options: .atomic); try await save(url: url); received += 1 } catch { failed += 1 }; try? FileManager.default.removeItem(at: url)
            }
            phase = .completed
        }
    }

    private func save(url: URL) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, fileURL: url, options: nil)
        }
    }
}
