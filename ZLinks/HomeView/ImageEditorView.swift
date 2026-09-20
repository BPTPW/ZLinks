//
//  ImageEditorView.swift
//  ZLinks
//

import ImageIO
import SwiftUI
import UIKit

struct ImageEditorAsset: Identifiable {
    let id = UUID()
    let url: URL
}

private enum ImageEditorTool: String, CaseIterable, Identifiable {
    case crop
    case filters
    case adjustments

    var id: String { rawValue }

    var title: String {
        switch self {
        case .crop: return "裁剪"
        case .filters: return "滤镜"
        case .adjustments: return "调整"
        }
    }

    var systemImage: String {
        switch self {
        case .crop: return "crop"
        case .filters: return "camera.filters"
        case .adjustments: return "slider.horizontal.3"
        }
    }
}

struct ImageEditorView: View {
    let asset: ImageEditorAsset
    let fallbackImage: UIImage?

    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var scale: CGFloat = 1
    @State private var settledScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var settledOffset: CGSize = .zero
    @State private var selectedTool: ImageEditorTool = .crop

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color(uiColor: .systemBackground).ignoresSafeArea()

                Group {
                    if let displayedImage = image ?? fallbackImage {
                        Image(uiImage: displayedImage)
                            .resizable()
                            .scaledToFit()
                            .allowedDynamicRange(.high)
                            .scaleEffect(scale)
                            .offset(offset)
                            .contentShape(Rectangle())
                            .gesture(dragGesture)
                            .simultaneousGesture(magnificationGesture)
                            .onTapGesture(count: 2, perform: toggleZoom)
                    } else {
                        ProgressView()
                            .tint(.primary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

                VStack(spacing: 0) {
                    HStack {
                        Button("取消") { dismiss() }
                            .buttonStyle(.plain)
                            .font(.subheadline.bold())
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 4)
                            .glassEffect(.regular.interactive(),in: .capsule)
                            .accessibilityLabel("取消编辑")

                        Spacer()

                        Button("导出", action: {})
                            .buttonStyle(.plain)
                            .font(.subheadline.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 4)
                            .glassEffect(.regular.interactive().tint(.blue),in: .capsule)
                            .accessibilityLabel("导出照片")
                    }
                    .padding(.horizontal, 48)
                    .frame(height: max(proxy.safeAreaInsets.top, 44))

                    Spacer()
                }
                .ignoresSafeArea(.container, edges: .top)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            toolBar
        }
        .statusBarHidden(true)
        .task(id: asset.url) {
            image = loadImage(from: asset.url)
        }
    }

    private var toolBar: some View {
        HStack(spacing: 0) {
            ForEach(ImageEditorTool.allCases) { tool in
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        selectedTool = tool
                    }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tool.systemImage)
                            .font(.system(size: 20, weight: .medium))
                            .symbolRenderingMode(.hierarchical)

                        Text(tool.title)
                            .font(.caption2.weight(.medium))
                    }
                    .foregroundStyle(selectedTool == tool ? Color.primary : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 58)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selectedTool == tool ? .isSelected : [])
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: 320)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(Color(uiColor: .systemBackground).ignoresSafeArea(edges: .bottom))
    }

    private var magnificationGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = min(max(settledScale * value.magnification, 1), 5)
            }
            .onEnded { _ in
                settledScale = scale
                if scale <= 1.01 { resetZoom() }
            }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard scale > 1.01 else { return }
                offset = CGSize(
                    width: settledOffset.width + value.translation.width,
                    height: settledOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                guard scale > 1.01 else { return }
                settledOffset = offset
            }
    }

    private func toggleZoom() {
        withAnimation(.interactiveSpring(response: 0.28, dampingFraction: 0.82)) {
            if scale > 1.01 {
                resetZoom()
            } else {
                scale = 2
                settledScale = 2
            }
        }
    }

    private func resetZoom() {
        scale = 1
        settledScale = 1
        offset = .zero
        settledOffset = .zero
    }

    private func loadImage(from url: URL) -> UIImage? {
        if let image = UIImage(contentsOfFile: url.path) {
            return image
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(
                  source,
                  0,
                  [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: 4_096
                  ] as CFDictionary
              )
        else { return nil }

        return UIImage(cgImage: cgImage)
    }
}
