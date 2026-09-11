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
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await reloadGallery(force: true) }
                    } label: {
                        if isRefreshing {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.body.weight(.semibold))
                        }
                    }
                    .disabled(!isConnected || isRefreshing)
                    .accessibilityLabel("刷新图库")
                }
            }
            .task(id: connectionTaskID) {
                await reloadGallery(force: false)
            }
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
        if isRefreshing && camera.galleryItems.isEmpty {
            ProgressView("正在读取图库…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError, camera.galleryItems.isEmpty {
            statusPlaceholder(
                title: "图库读取失败",
                systemImage: "exclamationmark.triangle",
                message: loadError
            )
        } else if camera.galleryItems.isEmpty {
            statusPlaceholder(
                title: "暂无媒体",
                systemImage: "photo",
                message: "相机存储中没有可显示的照片或视频。"
            )
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: spacing) {
                    ForEach(camera.galleryItems) { item in
                        // Outer size is owned by the grid column width; height is forced 1:1.
                        // The image is only drawn inside and cannot change the cell size.
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
            loadError = nil
            return
        }

        if !force, !camera.galleryItems.isEmpty {
            return
        }

        isRefreshing = true
        loadError = nil
        defer { isRefreshing = false }

        if force {
            thumbnailImages = [:]
            failedThumbnails = []
            visibleHandles = []
        }

        let previousHandles = Set(camera.galleryItems.map(\.handle))
        await camera.refreshGallery()

        let currentHandles = Set(camera.galleryItems.map(\.handle))
        let removed = previousHandles.subtracting(currentHandles)
        for handle in removed {
            thumbnailImages.removeValue(forKey: handle)
            failedThumbnails.remove(handle)
            visibleHandles.remove(handle)
        }

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
                // Allow a concurrent onAppear to land before stopping the pump.
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

            // Only fetch while the cell remains in the lazy viewport.
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
        // Keep gallery order so visible rows fill left-to-right, top-to-bottom.
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

private struct GalleryThumbnailCell: View {
    let item: CameraConnectionService.GalleryItem
    let image: UIImage?
    let cornerRadius: CGFloat
    let hasFailed: Bool

    var body: some View {
        // Layout size comes only from the parent 1:1 frame. Image content is drawn
        // inside with scaledToFill and never contributes to intrinsic size.
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
