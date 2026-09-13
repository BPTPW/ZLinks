//
//  GalleryView.swift
//  ZLinks
//

import Photos
import Combine
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import ImageIO
import MapKit
import CoreLocation

struct GalleryView: View {
    @EnvironmentObject private var camera: CameraConnectionService
    @StateObject private var downloadStore = GalleryDownloadStore()

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
    @State private var isDownloadDrawerPresented = false
    @State private var pendingMultiDownloads: [GalleryDownload] = []
    @State private var isMultiDownloadConfirmationPresented = false
    @State private var selectedItem: CameraConnectionService.GalleryItem?
    @State private var timeGrouping: GalleryTimeGrouping = .all
    @Namespace private var galleryTransition

    private let spacing: CGFloat = 2
    private let cornerRadius: CGFloat = 4

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: 0), spacing: spacing),
            count: timeGrouping.columnCount
        )
    }

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
                        message: "请先在“我的相机”中连接相机，再刷新图库。"
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
                            Button {
                                enterSelectionMode()
                            } label: {
                                Image(systemName: "checkmark.circle")
                            }
                            Button {
                                Task {
                                    await reloadGallery(force: true)
                                }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .disabled(!isConnected || isRefreshing || isDirectorySwitching)
                        }
                        .padding(.horizontal, 5)
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button { isDownloadDrawerPresented = true } label: {
                        Image(systemName: "arrow.down.circle.dotted")
                            .overlay(alignment: .topTrailing) {
                                if downloadStore.activeCount > 0 {
                                    Text("\(downloadStore.activeCount)")
                                        .font(.system(size: 10, weight: .bold, design: .rounded))
                                        .foregroundStyle(.white)
                                        .frame(minWidth: 17, minHeight: 17)
                                        .background(.blue, in: Capsule())
                                        .offset(x: 10, y: -9)
                                }
                            }
                    }
                    .accessibilityLabel("下载任务列表")
                }
            }
            .task(id: connectionTaskID) {
                downloadStore.cameraStateChanged(camera)
                await reloadGallery(force: false)
            }
            .onChange(of: camera.selectedGalleryDirectoryID) { _, newValue in
                if selectedDirectoryID != newValue {
                    selectedDirectoryID = newValue
                }
            }
            .onChange(of: camera.state) { _, _ in
                downloadStore.cameraStateChanged(camera)
            }
            .toolbar(isSelectionMode ? .hidden : .automatic, for: .tabBar)
            .safeAreaInset(edge: .bottom) {
                if isSelectionMode {
                    selectionToolbar
                } else if showsTimeGroupingPicker {
                    timeGroupingPicker
                        .padding(.horizontal, 36)
                        .padding(.vertical, 12)
                }
            }
            .sheet(isPresented: $isDownloadDrawerPresented) {
                DownloadTaskDrawer(store: downloadStore)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $isMultiDownloadConfirmationPresented) {
                MultiDownloadConfirmationSheet(
                    count: pendingMultiDownloads.count,
                    onConfirm: {
                        let downloads = pendingMultiDownloads
                        pendingMultiDownloads = []
                        isMultiDownloadConfirmationPresented = false
                        Task { await downloadStore.enqueue(downloads: downloads, camera: camera) }
                    },
                    onCancel: {
                        pendingMultiDownloads = []
                        isMultiDownloadConfirmationPresented = false
                    }
                )
                .presentationDetents([.height(250)])
                .presentationDragIndicator(.visible)
            }
            .navigationDestination(item: $selectedItem) { item in
                GalleryPreviewView(
                    item: item,
                    thumbnail: thumbnailImages[item.handle],
                    camera: camera,
                    onDownload: { format in
                        Task { await startTransfer(item: item, format: format) }
                    },
                    isDownloadQueued: { format in
                        downloadStore.contains(handle: item.handle, format: format)
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
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(gallerySections) { section in
                        if !section.title.isEmpty {
                            sectionHeader(for: section, isFirst: section.id == gallerySections.first?.id)
                        }

                        LazyVGrid(columns: columns, spacing: spacing) {
                            ForEach(section.items) { item in
                                galleryCell(for: item)
                            }
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

    private var showsTimeGroupingPicker: Bool {
        isConnected && !camera.galleryItems.isEmpty
    }

    private var timeGroupingPicker: some View {
        Picker("分类", selection: $timeGrouping) {
            ForEach(GalleryTimeGrouping.allCases) { mode in
                Text(mode.title).tag(mode)
                    .font(.headline)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular,in: .capsule)
        .accessibilityLabel("按时间分类")
    }

    private var gallerySections: [GalleryTimeSection] {
        let items = camera.galleryItems
        guard timeGrouping != .all else {
            return [GalleryTimeSection(id: "all", title: "", items: items)]
        }

        let calendar = Calendar.current
        var sections: [GalleryTimeSection] = []
        var currentKey: String?
        var currentTitle = ""
        var currentItems: [CameraConnectionService.GalleryItem] = []

        for item in items {
            let identity = timeSectionIdentity(for: item.captureDate, mode: timeGrouping, calendar: calendar)
            if identity.key != currentKey {
                if let currentKey, !currentItems.isEmpty {
                    sections.append(
                        GalleryTimeSection(id: currentKey, title: currentTitle, items: currentItems)
                    )
                }
                currentKey = identity.key
                currentTitle = identity.title
                currentItems = [item]
            } else {
                currentItems.append(item)
            }
        }

        if let currentKey, !currentItems.isEmpty {
            sections.append(
                GalleryTimeSection(id: currentKey, title: currentTitle, items: currentItems)
            )
        }

        return sections
    }

    private func timeSectionIdentity(
        for date: Date?,
        mode: GalleryTimeGrouping,
        calendar: Calendar
    ) -> (key: String, title: String) {
        guard let date else {
            return ("unknown", "未知日期")
        }

        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year else {
            return ("unknown", "未知日期")
        }

        switch mode {
        case .year:
            return ("y-\(year)", "\(year)年")
        case .month:
            let month = components.month ?? 1
            return ("y-\(year)-m-\(month)", "\(year)年\(month)月")
        case .day:
            let month = components.month ?? 1
            let day = components.day ?? 1
            return ("y-\(year)-m-\(month)-d-\(day)", "\(year)年\(month)月\(day)日")
        case .all:
            return ("all", "")
        }
    }

    @ViewBuilder
    private func galleryCell(for item: CameraConnectionService.GalleryItem) -> some View {
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
                if selectedHandles.contains(item.handle) {
                    selectedHandles.remove(item.handle)
                } else {
                    selectedHandles.insert(item.handle)
                }
            } else {
                selectedItem = item
            }
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
                        Task { await startTransfer(item: item, format: .raw) }
                    } label: {
                        Label("下载 RAW", systemImage: "r.square")
                    }
                }
                if format.supportsJPEG {
                    Button {
                        Task { await startTransfer(item: item, format: .jpeg) }
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

    @ViewBuilder
    private func sectionHeader(for section: GalleryTimeSection, isFirst: Bool) -> some View {
        let handles = selectableHandles(in: section)
        let isFullySelected = !handles.isEmpty && handles.allSatisfy(selectedHandles.contains)

        HStack(spacing: 8) {
            Text(section.title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                toggleSectionSelection(section)
            } label: {
                Image(systemName: isFullySelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .regular))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(isFullySelected ? .white : .secondary, isFullySelected ? .blue : .secondary)
                    .symbolRenderingMode(.monochrome)
            }
            .buttonStyle(.plain)
            .disabled(handles.isEmpty)
            .opacity(handles.isEmpty ? 0.35 : 1)
            .accessibilityLabel(isFullySelected ? "取消选择本分类全部照片" : "选择本分类全部照片")
        }
        .padding(.horizontal, 8)
        .padding(.top, isFirst ? 6 : 22)
        .padding(.bottom, 12)
    }

    private func selectableHandles(in section: GalleryTimeSection) -> [UInt32] {
        section.items.compactMap { item in
            item.isVideo ? nil : item.handle
        }
    }

    private func toggleSectionSelection(_ section: GalleryTimeSection) {
        let handles = selectableHandles(in: section)
        guard !handles.isEmpty else { return }

        let isFullySelected = handles.allSatisfy(selectedHandles.contains)
        if isFullySelected {
            for handle in handles {
                selectedHandles.remove(handle)
            }
        } else {
            if !isSelectionMode {
                isSelectionMode = true
            }
            selectedHandles.formUnion(handles)
        }
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
        pendingMultiDownloads = downloads
        isMultiDownloadConfirmationPresented = true
        exitSelectionMode()
    }

    private func startTransfer(item: CameraConnectionService.GalleryItem, format: GalleryDownloadFormat) async {
        guard let download = makeDownload(for: item, format: format, fallbackToOtherFormat: false) else {
            return
        }
        await downloadStore.enqueue(downloads: [download], camera: camera)
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
            format: requestedFormat,
            thumbnailHandle: item.thumbnailHandle
        )
    }

    private func startTransfer(downloads: [GalleryDownload], requiresConfirmation: Bool) {
        guard !downloads.isEmpty else { return }
        pendingMultiDownloads = downloads
        isMultiDownloadConfirmationPresented = requiresConfirmation
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
            let needsThumb =
                thumbnailImages[item.handle] == nil
                    && !failedThumbnails.contains(item.handle)
            if needsThumb {
                return item
            }
        }
        return nil
    }
}

private enum GalleryTimeGrouping: String, CaseIterable, Identifiable {
    case year
    case month
    case day
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .year: return "年"
        case .month: return "月"
        case .day: return "日"
        case .all: return "全部"
        }
    }

    var columnCount: Int {
        switch self {
        case .year: return 6
        case .month: return 4
        case .day, .all: return 3
        }
    }
}

private struct GalleryTimeSection: Identifiable, Equatable {
    let id: String
    let title: String
    let items: [CameraConnectionService.GalleryItem]
}

private enum GalleryDownloadFormat: String, Hashable, Codable {
    case raw
    case jpeg
}

private struct GalleryDownload: Identifiable, Hashable {
    let handle: UInt32
    let filename: String
    let fileSize: UInt64
    let format: GalleryDownloadFormat
    let thumbnailHandle: UInt32

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
    let isDownloadQueued: (GalleryDownloadFormat) -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var isLoading = false
    @State private var isHighQualityPreview = false
    @State private var isOriginalImageLoading = false
    @State private var hasLoadFailed = false
    @State private var scale: CGFloat = 1
    @State private var settledScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var settledOffset: CGSize = .zero
    @State private var controlsVisible = true
    @State private var dragOffset: CGFloat = 0
    @State private var isMetadataPresented = false
    @State private var metadata: GalleryMetadata?
    @State private var isMetadataLoading = false

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
                        if isHighQualityPreview {
                            Button(action: loadOriginalImage) {
                                VStack(spacing: 2) {
                                    Text("高清预览")
                                        .font(.caption.weight(.semibold))
                                    if isOriginalImageLoading {
                                        HStack(spacing: 5) {
                                            ProgressView()
                                                .controlSize(.mini)
                                            Text("正在加载原图…")
                                                .font(.caption2)
                                        }
                                    } else {
                                        Text("点击查看原图")
                                            .font(.caption2)
                                    }
                                }
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                            }
                            .buttonStyle(.plain)
                            .glassEffect(.regular.interactive(), in: .capsule)
                            .disabled(isOriginalImageLoading)
                            .accessibilityLabel("查看原图")
                            .padding(.bottom, 10)
                        }
                        HStack {
                            if let format = item.photoFormat {
                                Menu {
                                    if format.supportsRAW {
                                        Button { onDownload(.raw) } label: {
                                            Label("下载 RAW", systemImage: "r.square")
                                        }
                                        .disabled(isDownloadQueued(.raw))
                                    }
                                    if format.supportsJPEG {
                                        Button { onDownload(.jpeg) } label: {
                                            Label("下载 JPEG", systemImage: "j.square")
                                        }
                                        .disabled(isDownloadQueued(.jpeg))
                                    }
                                } label: {
                                    Image(systemName: isAnyDownloadQueued ? "square.and.arrow.down.badge.clock" : "square.and.arrow.down")
                                        .foregroundStyle(.primary)
                                        .contentTransition(.symbolEffect(.replace.magic(fallback: .downUp.byLayer), options: .nonRepeating))
                                }
                                .buttonStyle(.plain)
                                .frame(width: 42, height: 42)
                                .glassEffect(.regular.interactive(), in: .circle)
                            }
                            Spacer()
                            if !item.isVideo {
                                Button {
                                    isMetadataPresented = true
                                } label: {
                                    Image(systemName: "info")
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.primary)
                                }
                                .buttonStyle(.plain)
                                .frame(width: 42, height: 42)
                                .glassEffect(.regular.interactive(), in: .circle)
                                .accessibilityLabel("照片信息")
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
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
            .sheet(isPresented: $isMetadataPresented) {
                GalleryMetadataSheet(
                    metadata: metadata,
                    isLoading: isMetadataLoading
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .task { await loadMetadata() }
            }
        }
    }

    private var isImmersive: Bool { scale > 1.01 || !controlsVisible }
    private var isAnyDownloadQueued: Bool {
        guard let format = item.photoFormat else { return false }
        return (format.supportsRAW && isDownloadQueued(.raw)) || (format.supportsJPEG && isDownloadQueued(.jpeg))
    }

    @ViewBuilder
    private var captureTimestampView: some View {
        if let captureDateParts {
            VStack() {
                Text(captureDateParts.date)
                    .font(.caption.weight(.semibold))
                    
                Text(captureDateParts.time)
                    .font(.caption2)
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
            let result = await camera.galleryPreviewImage(for: item.previewHandle)
            await MainActor.run {
                withAnimation(.easeIn(duration: 0.28)) {
                    switch result {
                    case .preview(let loaded):
                        image = loaded
                        isHighQualityPreview = true
                        hasLoadFailed = false
                    case .original(let loaded):
                        image = loaded
                        isHighQualityPreview = false
                        hasLoadFailed = false
                    case nil:
                        image = nil
                        isHighQualityPreview = false
                        hasLoadFailed = true
                    }
                    isLoading = false
                }
            }
        }
    }

    private func loadOriginalImage() {
        guard isHighQualityPreview, !isOriginalImageLoading else { return }
        isOriginalImageLoading = true
        Task {
            let loaded = await camera.objectImage(for: item.previewHandle)
            await MainActor.run {
                withAnimation(.easeIn(duration: 0.28)) {
                    if let loaded {
                        image = loaded
                        isHighQualityPreview = false
                        hasLoadFailed = false
                    }
                    isOriginalImageLoading = false
                }
            }
        }
    }

    private func loadMetadata() async {
        guard !isMetadataLoading else { return }
        if metadata != nil { return }

        isMetadataLoading = true
        defer { isMetadataLoading = false }

        guard let data = await camera.objectData(for: item.previewHandle) else {
            metadata = GalleryMetadata(sections: [], coordinate: nil)
            return
        }

        metadata = GalleryMetadataParser.parse(data: data)
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

private struct GalleryMetadata: Equatable {
    struct Section: Identifiable, Equatable {
        struct Row: Identifiable, Equatable {
            let id: String
            let label: String
            let value: String
        }

        let id: String
        let title: String
        let rows: [Row]
    }

    let sections: [Section]
    let coordinate: CLLocationCoordinate2D?

    static func == (lhs: GalleryMetadata, rhs: GalleryMetadata) -> Bool {
        lhs.sections == rhs.sections
            && lhs.coordinate?.latitude == rhs.coordinate?.latitude
            && lhs.coordinate?.longitude == rhs.coordinate?.longitude
    }
}

private enum GalleryMetadataParser {
    private struct Builder {
        var rows: [GalleryMetadata.Section.Row] = []

        mutating func add(_ label: String, _ value: String?) {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
            rows.append(.init(id: label, label: label, value: value))
        }
    }

    static func parse(data: Data) -> GalleryMetadata {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        else {
            return GalleryMetadata(sections: [], coordinate: nil)
        }

        var sections: [GalleryMetadata.Section] = []
        var gpsCoordinate: CLLocationCoordinate2D?

        var image = Builder()
        image.add("格式", imageFormat(CGImageSourceGetType(source)))
        image.add("宽度", integerText(properties[kCGImagePropertyPixelWidth as String]))
        image.add("高度", integerText(properties[kCGImagePropertyPixelHeight as String]))
        image.add("位深", integerText(properties[kCGImagePropertyDepth as String]))
        image.add("颜色模型", stringValue(properties[kCGImagePropertyColorModel as String]))
        image.add("色彩空间", stringValue(properties[kCGImagePropertyProfileName as String]))
        image.add("方向", orientationText(properties[kCGImagePropertyOrientation as String]))
        appendSection(&sections, title: "图像", rows: image.rows)

        if let tiff = dictionary(properties[kCGImagePropertyTIFFDictionary as String]) {
            var builder = Builder()
            builder.add("品牌", stringValue(tiff[kCGImagePropertyTIFFMake as String]))
            builder.add("型号", stringValue(tiff[kCGImagePropertyTIFFModel as String]))
            builder.add("软件", stringValue(tiff[kCGImagePropertyTIFFSoftware as String]))
            builder.add("作者", stringValue(tiff[kCGImagePropertyTIFFArtist as String]))
            builder.add("版权", stringValue(tiff[kCGImagePropertyTIFFCopyright as String]))
            builder.add("拍摄时间", stringValue(tiff[kCGImagePropertyTIFFDateTime as String]))
            appendSection(&sections, title: "相机", rows: builder.rows)
        }

        if let exif = dictionary(properties[kCGImagePropertyExifDictionary as String]) {
            var builder = Builder()
            builder.add("原始拍摄时间", stringValue(exif[kCGImagePropertyExifDateTimeOriginal as String]))
            builder.add("数字化时间", stringValue(exif[kCGImagePropertyExifDateTimeDigitized as String]))
            builder.add("曝光时间", exposureTimeText(exif[kCGImagePropertyExifExposureTime as String]))
            builder.add("光圈", fNumberText(exif[kCGImagePropertyExifFNumber as String]))
            builder.add("ISO", isoText(exif[kCGImagePropertyExifISOSpeedRatings as String]))
            builder.add("焦距", focalLengthText(exif[kCGImagePropertyExifFocalLength as String]))
            builder.add("35mm 等效焦距", focalLengthText(exif[kCGImagePropertyExifFocalLenIn35mmFilm as String]))
            builder.add("曝光补偿", evText(exif[kCGImagePropertyExifExposureBiasValue as String]))
            builder.add("测光模式", stringValue(exif[kCGImagePropertyExifMeteringMode as String]))
            builder.add("闪光灯", stringValue(exif[kCGImagePropertyExifFlash as String]))
            builder.add("白平衡", stringValue(exif[kCGImagePropertyExifWhiteBalance as String]))
            builder.add("镜头品牌", stringValue(exif[kCGImagePropertyExifLensMake as String]))
            builder.add("镜头型号", stringValue(exif[kCGImagePropertyExifLensModel as String]))
            builder.add("镜头序列号", stringValue(exif[kCGImagePropertyExifLensSerialNumber as String]))
            builder.add("机身序列号", stringValue(exif[kCGImagePropertyExifBodySerialNumber as String]))
            builder.add("相机所有者", stringValue(exif[kCGImagePropertyExifCameraOwnerName as String]))
            builder.add("用户备注", stringValue(exif[kCGImagePropertyExifUserComment as String]))
            appendSection(&sections, title: "EXIF", rows: builder.rows)
        }

        if let gps = dictionary(properties[kCGImagePropertyGPSDictionary as String]) {
            var builder = Builder()
            let latitude = rationalCoordinate(gps[kCGImagePropertyGPSLatitude as String])
            let longitude = rationalCoordinate(gps[kCGImagePropertyGPSLongitude as String])
            let latitudeRef = stringValue(gps[kCGImagePropertyGPSLatitudeRef as String])?.uppercased()
            let longitudeRef = stringValue(gps[kCGImagePropertyGPSLongitudeRef as String])?.uppercased()
            let signedLatitude = signedCoordinate(latitude, reference: latitudeRef, negativeReference: "S")
            let signedLongitude = signedCoordinate(longitude, reference: longitudeRef, negativeReference: "W")

            if let signedLatitude, let signedLongitude,
               (-90...90).contains(signedLatitude), (-180...180).contains(signedLongitude)
            {
                gpsCoordinate = CLLocationCoordinate2D(latitude: signedLatitude, longitude: signedLongitude)
                builder.add("纬度", String(format: "%.6f° %@", abs(signedLatitude), signedLatitude < 0 ? "S" : "N"))
                builder.add("经度", String(format: "%.6f° %@", abs(signedLongitude), signedLongitude < 0 ? "W" : "E"))
            }
            builder.add("海拔", distanceText(gps[kCGImagePropertyGPSAltitude as String], unit: "m"))
            builder.add("GPS 时间", stringValue(gps[kCGImagePropertyGPSTimeStamp as String]))
            builder.add("方向", angleText(gps[kCGImagePropertyGPSImgDirection as String]))
            builder.add("定位误差", distanceText(gps[kCGImagePropertyGPSHPositioningError as String], unit: "m"))
            appendSection(&sections, title: "GPS", rows: builder.rows)
        }

        if let iptc = dictionary(properties[kCGImagePropertyIPTCDictionary as String]) {
            var builder = Builder()
            builder.add("标题", stringValue(iptc[kCGImagePropertyIPTCHeadline as String]))
            builder.add("说明", stringValue(iptc[kCGImagePropertyIPTCCaptionAbstract as String]))
            builder.add("作者", stringValue(iptc[kCGImagePropertyIPTCByline as String]))
            builder.add("城市", stringValue(iptc[kCGImagePropertyIPTCCity as String]))
            builder.add("国家", stringValue(iptc[kCGImagePropertyIPTCCountryPrimaryLocationName as String]))
            builder.add("关键词", stringValue(iptc[kCGImagePropertyIPTCKeywords as String]))
            appendSection(&sections, title: "IPTC", rows: builder.rows)
        }

        return GalleryMetadata(sections: sections, coordinate: gpsCoordinate)
    }

    private static func appendSection(
        _ sections: inout [GalleryMetadata.Section],
        title: String,
        rows: [GalleryMetadata.Section.Row]
    ) {
        guard !rows.isEmpty else { return }
        sections.append(.init(id: title, title: title, rows: rows))
    }

    private static func dictionary(_ value: Any?) -> [String: Any]? {
        guard let value else { return nil }
        return (value as? NSDictionary) as? [String: Any]
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        if let values = value as? [Any] {
            let strings = values.compactMap { stringValue($0) }
            return strings.isEmpty ? nil : strings.joined(separator: ", ")
        }
        return nil
    }

    private static func integerText(_ value: Any?) -> String? {
        guard let number = value as? NSNumber else { return stringValue(value) }
        return number.int64Value.formatted()
    }

    private static func imageFormat(_ type: CFString?) -> String? {
        guard let type else { return nil }
        let value = type as String
        switch value.lowercased() {
        case "public.jpeg": return "JPEG"
        case "public.heic": return "HEIC"
        case "public.tiff": return "TIFF"
        case "com.adobe.raw-image": return "RAW"
        default: return value
        }
    }

    private static func orientationText(_ value: Any?) -> String? {
        guard let number = value as? NSNumber else { return nil }
        let names = [1: "正常", 2: "水平翻转", 3: "旋转 180°", 4: "垂直翻转", 5: "水平翻转并旋转 270°", 6: "旋转 90°", 7: "水平翻转并旋转 90°", 8: "旋转 270°"]
        return names[number.intValue] ?? number.stringValue
    }

    private static func exposureTimeText(_ value: Any?) -> String? {
        guard let seconds = rationalValue(value) else { return nil }
        if seconds >= 1 { return String(format: "%.2f s", seconds) }
        guard seconds > 0 else { return nil }
        return String(format: "1/%d s", max(Int((1 / seconds).rounded()), 1))
    }

    private static func fNumberText(_ value: Any?) -> String? {
        guard let value = rationalValue(value) else { return nil }
        return String(format: "ƒ/%.1f", value)
    }

    private static func focalLengthText(_ value: Any?) -> String? {
        guard let value = rationalValue(value) ?? doubleValue(value) else { return nil }
        return String(format: "%.1f mm", value)
    }

    private static func isoText(_ value: Any?) -> String? {
        if let values = value as? [Any], let first = values.first { return integerText(first) }
        return integerText(value)
    }

    private static func evText(_ value: Any?) -> String? {
        guard let value = rationalValue(value) else { return nil }
        return String(format: "%+.2f EV", value)
    }

    private static func distanceText(_ value: Any?, unit: String) -> String? {
        guard let value = rationalValue(value) ?? doubleValue(value) else { return nil }
        return String(format: "%.1f %@", value, unit)
    }

    private static func angleText(_ value: Any?) -> String? {
        guard let value = rationalValue(value) ?? doubleValue(value) else { return nil }
        return String(format: "%.1f°", value)
    }

    private static func rationalCoordinate(_ value: Any?) -> Double? {
        if let parts = value as? [Any], parts.count >= 3 {
            let degrees = rationalValue(parts[0]) ?? 0
            let minutes = rationalValue(parts[1]) ?? 0
            let seconds = rationalValue(parts[2]) ?? 0
            return degrees + minutes / 60 + seconds / 3600
        }
        return rationalValue(value) ?? doubleValue(value)
    }

    private static func signedCoordinate(_ value: Double?, reference: String?, negativeReference: String) -> Double? {
        guard let value else { return nil }
        return reference == negativeReference ? -abs(value) : abs(value)
    }

    private static func rationalValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let values = value as? [Any], values.count == 2,
           let numerator = doubleValue(values[0]), let denominator = doubleValue(values[1]), denominator != 0
        {
            return numerator / denominator
        }
        if let dictionary = value as? [String: Any],
           let numerator = doubleValue(dictionary["numerator"]),
           let denominator = doubleValue(dictionary["denominator"]), denominator != 0
        {
            return numerator / denominator
        }
        return doubleValue(value)
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }
}

private struct GalleryMetadataSheet: View {
    let metadata: GalleryMetadata?
    let isLoading: Bool

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("正在解析照片信息…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let metadata, !metadata.sections.isEmpty {
                    List {
                        ForEach(metadata.sections) { section in
                            Section(section.title) {
                                ForEach(section.rows) { row in
                                    LabeledContent(row.label) {
                                        Text(row.value)
                                            .multilineTextAlignment(.trailing)
                                    }
                                }
                            }
                        }

                        if let coordinate = metadata.coordinate {
                            GalleryMetadataMapView(coordinate: coordinate)
                                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                        }
                    }
                    .listStyle(.insetGrouped)
                } else {
                    ContentUnavailableView("没有可用信息", systemImage: "info.circle", description: Text("这张照片没有可解析的 EXIF 数据。"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("照片信息")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct GalleryMetadataMapView: View {
    let coordinate: CLLocationCoordinate2D
    @State private var placeName = "拍摄位置"

    var body: some View {
        Map(initialPosition: .region(
            MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
            )
        )) {
            Marker(placeName, coordinate: coordinate)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 200)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .task(id: coordinateIdentifier) {
            if let name = await fetchPlaceName() {
                placeName = name
            }
        }
    }

    private var coordinateIdentifier: String {
        "\(coordinate.latitude),\(coordinate.longitude)"
    }

    private func fetchPlaceName() async -> String? {
        let geocoder = CLGeocoder()
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
            guard let placemark = placemarks.first else { return nil }
            return placemark.name ?? placemark.locality
        } catch {
            return nil
        }
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
                if item.isVideo {
                    thumbnailBadge(symbol: "play.circle.fill", color: .white)
                } else if let format = item.photoFormat, let symbol = format.thumbnailSymbol {
                    thumbnailBadge(symbol: symbol, color: format == .raw ? .orange : .white)
                }
            }
            .overlay {
                if selectionMode && isSelected {
                    Color.white.opacity(0.42)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .blue)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(6)
                }
            }
            .accessibilityLabel(accessibilityLabel)
    }

    private func thumbnailBadge(symbol: String, color: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 24, height: 24)
            .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 4))
            .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
            .padding(5)
    }

    private var accessibilityLabel: String {
        if item.isVideo {
            return "视频 \(item.filename)"
        }
        let format = item.photoFormat?.title ?? "照片"
        return "\(format) \(item.filename)"
    }
}

#Preview {
    GalleryView()
        .environmentObject(CameraConnectionService())
}

@MainActor
private final class GalleryDownloadStore: ObservableObject {
    enum Status: String, CaseIterable, Codable {
        case waiting, downloading, cancelled, failed, completed

        var title: String {
            switch self {
            case .waiting: return "等待"
            case .downloading: return "下载中"
            case .cancelled: return "取消"
            case .failed: return "失败"
            case .completed: return "完成"
            }
        }
    }

    struct TaskItem: Identifiable {
        let id: String
        let handle: UInt32
        let filename: String
        var fileSize: UInt64
        let format: GalleryDownloadFormat
        let thumbnailURL: URL?
        var status: Status
        var receivedBytes: UInt64 = 0
        var speed: Double = 0
        var task: Task<Void, Never>?
        var addedAt: Date
        var errorMessage: String?
    }

    private struct PersistedTask: Codable {
        let id: String
        let handle: UInt32
        let filename: String
        let fileSize: UInt64
        let format: GalleryDownloadFormat
        let thumbnailPath: String?
        let status: Status
        let receivedBytes: UInt64
        let addedAt: Date
        let errorMessage: String?

        init(
            id: String,
            handle: UInt32,
            filename: String,
            fileSize: UInt64,
            format: GalleryDownloadFormat,
            thumbnailPath: String?,
            status: Status,
            receivedBytes: UInt64,
            addedAt: Date,
            errorMessage: String?
        ) {
            self.id = id
            self.handle = handle
            self.filename = filename
            self.fileSize = fileSize
            self.format = format
            self.thumbnailPath = thumbnailPath
            self.status = status
            self.receivedBytes = receivedBytes
            self.addedAt = addedAt
            self.errorMessage = errorMessage
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            handle = try container.decode(UInt32.self, forKey: .handle)
            filename = try container.decode(String.self, forKey: .filename)
            fileSize = try container.decode(UInt64.self, forKey: .fileSize)
            format = try container.decode(GalleryDownloadFormat.self, forKey: .format)
            thumbnailPath = try container.decodeIfPresent(String.self, forKey: .thumbnailPath)
            status = try container.decode(Status.self, forKey: .status)
            receivedBytes = try container.decode(UInt64.self, forKey: .receivedBytes)
            addedAt = try container.decode(Date.self, forKey: .addedAt)
            errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        }
    }

    @Published private(set) var items: [TaskItem] = []
    private var worker: Task<Void, Never>?
    private var camera: CameraConnectionService?
    private var lastPersistedAt = Date.distantPast

    private var persistenceURL: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("gallery-download-tasks.json")
    }

    init() {
        loadPersistedTasks()
    }

    var activeCount: Int {
        items.reduce(into: 0) { count, item in
            if item.status == .waiting || item.status == .downloading { count += 1 }
        }
    }

    func contains(handle: UInt32, format: GalleryDownloadFormat) -> Bool {
        items.contains { $0.handle == handle && $0.format == format && $0.status != .completed }
    }

    func enqueue(downloads: [GalleryDownload], camera: CameraConnectionService) async {
        self.camera = camera
        for download in downloads where !contains(handle: download.handle, format: download.format) {
            let thumbnailURL = await saveThumbnail(for: download, camera: camera)
            items.append(TaskItem(
                id: download.id,
                handle: download.handle,
                filename: download.filename,
                fileSize: download.fileSize,
                format: download.format,
                thumbnailURL: thumbnailURL,
                status: .waiting,
                addedAt: Date(),
                errorMessage: nil
            ))
        }
        persistTasks()
        startWorkerIfNeeded()
    }

    func cameraStateChanged(_ camera: CameraConnectionService) {
        self.camera = camera
        if case .connected = camera.state { startWorkerIfNeeded() }
    }

    func cancel(_ id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].task?.cancel()
        items[index].task = nil
        if items[index].status == .downloading || items[index].status == .waiting {
            items[index].status = .cancelled
        }
        persistTasks()
        startWorkerIfNeeded()
    }

    func retry(_ id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              items[index].status == .cancelled || items[index].status == .failed
        else { return }
        items[index].status = .waiting
        items[index].receivedBytes = 0
        items[index].speed = 0
        items[index].errorMessage = nil
        persistTasks()
        startWorkerIfNeeded()
    }

    func delete(_ id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].task?.cancel()
        if let url = items[index].thumbnailURL { try? FileManager.default.removeItem(at: url) }
        items.remove(at: index)
        persistTasks()
    }

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        worker = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard let camera = self.camera else { break }
                guard case .connected = camera.state else {
                    self.markActiveTasksWaiting()
                    break
                }
                guard let index = self.nextIndex else { break }
                await self.process(index: index, camera: camera)
            }
            self.worker = nil
            self.persistTasks()
        }
    }

    private var nextIndex: Int? {
        items.firstIndex { $0.status == .waiting || $0.status == .downloading }
    }

    private func markActiveTasksWaiting() {
        for index in items.indices where items[index].status == .downloading {
            items[index].status = .waiting
            items[index].task = nil
        }
        persistTasks()
    }

    private func process(index: Int, camera: CameraConnectionService) async {
        guard items.indices.contains(index) else { return }
        items[index].status = .downloading
        items[index].receivedBytes = 0
        items[index].errorMessage = nil
        let started = Date()
        let id = items[index].id
        do {
            let data = try await camera.objectData(for: items[index].handle) { [weak self] received, total in
                guard let self, let current = self.items.firstIndex(where: { $0.id == id }) else { return }
                self.items[current].receivedBytes = received
                self.items[current].speed = Date().timeIntervalSince(started) > 0
                    ? Double(received) / Date().timeIntervalSince(started)
                    : 0
                if total > 0 && self.items[current].fileSize == 0 {
                    self.items[current].fileSize = total
                }
                self.persistTasksIfNeeded()
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + items[index].filename)
            try data.write(to: url, options: .atomic)
            try await saveToPhotos(url: url)
            try? FileManager.default.removeItem(at: url)
            if let current = items.firstIndex(where: { $0.id == id }) {
                items[current].receivedBytes = items[current].fileSize
                items[current].status = .completed
                items[current].task = nil
                items[current].errorMessage = nil
                persistTasks()
            }
        } catch is CancellationError {
            if let current = items.firstIndex(where: { $0.id == id }), items[current].status == .downloading {
                items[current].status = .cancelled
                persistTasks()
            }
        } catch {
            if let current = items.firstIndex(where: { $0.id == id }) {
                if case .connected = camera.state {
                    items[current].status = .failed
                    items[current].errorMessage = error.localizedDescription
                } else {
                    items[current].status = .waiting
                    items[current].errorMessage = nil
                }
                items[current].task = nil
                persistTasks()
            }
        }
    }

    private func saveThumbnail(for download: GalleryDownload, camera: CameraConnectionService) async -> URL? {
        guard let image = await camera.thumbnailImage(for: download.thumbnailHandle),
              let data = image.jpegData(compressionQuality: 0.82)
        else { return nil }
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GalleryDownloadThumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(download.id.replacingOccurrences(of: "/", with: "_") + ".jpg")
        do { try data.write(to: url, options: .atomic); return url } catch { return nil }
    }

    private func loadPersistedTasks() {
        guard let data = try? Data(contentsOf: persistenceURL),
              let saved = try? JSONDecoder().decode([PersistedTask].self, from: data)
        else { return }

        let expiration = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        items = saved.compactMap { task in
            if task.status == .completed && task.addedAt < expiration {
                if let path = task.thumbnailPath { try? FileManager.default.removeItem(atPath: path) }
                return nil
            }
            return TaskItem(
                id: task.id,
                handle: task.handle,
                filename: task.filename,
                fileSize: task.fileSize,
                format: task.format,
                thumbnailURL: task.thumbnailPath.map(URL.init(fileURLWithPath:)),
                status: task.status == .downloading ? .waiting : task.status,
                receivedBytes: task.status == .downloading ? 0 : task.receivedBytes,
                addedAt: task.addedAt,
                errorMessage: task.errorMessage
            )
        }
        persistTasks()
    }

    private func persistTasksIfNeeded() {
        guard Date().timeIntervalSince(lastPersistedAt) >= 0.25 else { return }
        persistTasks()
    }

    private func persistTasks() {
        lastPersistedAt = Date()
        let saved = items.map {
            PersistedTask(
                id: $0.id,
                handle: $0.handle,
                filename: $0.filename,
                fileSize: $0.fileSize,
                format: $0.format,
                thumbnailPath: $0.thumbnailURL?.path,
                status: $0.status,
                receivedBytes: $0.receivedBytes,
                addedAt: $0.addedAt,
                errorMessage: $0.errorMessage
            )
        }
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? data.write(to: persistenceURL, options: .atomic)
    }

    private func saveToPhotos(url: URL) async throws {
        let auth = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard auth == .authorized || auth == .limited else { throw CocoaError(.fileWriteNoPermission) }
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, fileURL: url, options: nil)
        }
    }
}

private struct MultiDownloadConfirmationSheet: View {
    let count: Int
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Text("保存 \(count) 张图片到相册")
                    .font(.headline)
                Spacer()
                HStack(spacing: 12) {
                    Button("取消", action: onCancel)
                        .buttonStyle(.bordered)
                    Button("确认", action: onConfirm)
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
            .navigationTitle("确认下载")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct DownloadTaskDrawer: View {
    @ObservedObject var store: GalleryDownloadStore
    @State private var tab: Tab = .waiting
    @Environment(\.dismiss) private var dismiss

    enum Tab: String, CaseIterable { case waiting = "未下载", completed = "已下载" }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("任务类型", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                List {
                    ForEach(filteredItems) { item in
                        DownloadTaskRow(item: item, store: store)
                            .swipeActions(edge: .trailing) { Button(role: .destructive) { store.delete(item.id) } label: { Label("删除", systemImage: "trash") } }
                    }
                    if tab == .completed {
                        Text("已完成的下载任务记录最多保留7天")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden, edges: .all)
                    }
                }
                .listStyle(.plain)
            }
            .navigationTitle("任务列表")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
        }
    }

    private var filteredItems: [GalleryDownloadStore.TaskItem] {
        switch tab {
        case .waiting:
            return store.items.filter { $0.status != .completed }.sorted { rank($0.status) < rank($1.status) }
        case .completed:
            return store.items.filter { $0.status == .completed }
        }
    }

    private func rank(_ status: GalleryDownloadStore.Status) -> Int {
        switch status { case .downloading: return 0; case .waiting: return 1; case .failed: return 2; case .cancelled: return 3; case .completed: return 4 }
    }
}

private struct DownloadTaskRow: View {
    let item: GalleryDownloadStore.TaskItem
    @ObservedObject var store: GalleryDownloadStore

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let url = item.thumbnailURL, let image = UIImage(contentsOfFile: url.path) { Image(uiImage: image).resizable().scaledToFill() }
                else { Image(systemName: "photo").foregroundStyle(.secondary) }
            }
            .frame(width: 58, height: 58)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 5) {
                Text(item.filename).lineLimit(1).font(.subheadline.weight(.medium))
                if item.status == .failed, let errorMessage = item.errorMessage, !errorMessage.isEmpty {
                    Text("错误: \(errorMessage)")
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                if item.status == .downloading {
                    ProgressView(value: item.fileSize > 0 ? Double(item.receivedBytes) / Double(item.fileSize) : 0)
                    HStack {
                        Spacer()
                        Text("\(formatSpeed(item.speed))  \(formatBytes(item.receivedBytes))/\(formatBytes(item.fileSize))")
                    }.font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if item.status == .waiting || item.status == .downloading {
                Button { store.cancel(item.id) } label: { Image(systemName: "xmark.circle.fill").symbolRenderingMode(.multicolor).font(.headline) }.buttonStyle(.plain)
            } else if item.status == .cancelled || item.status == .failed {
                Button { store.retry(item.id) } label: { Image(systemName: "arrow.clockwise").font(.headline) }.buttonStyle(.plain)
            }
        }
        .padding(.vertical, 5)
        .contentTransition(.symbolEffect(.replace.magic(fallback: .downUp.byLayer), options: .nonRepeating))
        .animation(.default, value: item.status)
    }

    private func formatSpeed(_ speed: Double) -> String { "\(formatBytes(UInt64(speed)))/秒" }
    private func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
