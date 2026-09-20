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

private enum ImageCropAspect: String, CaseIterable, Identifiable {
    case original
    case fourThree
    case square
    case threeTwo
    case sixteenNine
    case twentyOneTen
    case free

    var id: String { rawValue }

    var landscapeRatio: CGFloat? {
        switch self {
        case .original, .free: return nil
        case .fourThree: return 4 / 3
        case .square: return 1
        case .threeTwo: return 3 / 2
        case .sixteenNine: return 16 / 9
        case .twentyOneTen: return 21 / 10
        }
    }

    func title(isPortrait: Bool) -> String {
        switch self {
        case .original: return "原始比例"
        case .fourThree: return isPortrait ? "3:4" : "4:3"
        case .square: return "1:1"
        case .threeTwo: return isPortrait ? "2:3" : "3:2"
        case .sixteenNine: return isPortrait ? "9:16" : "16:9"
        case .twentyOneTen: return isPortrait ? "10:21" : "21:10"
        case .free: return "自由尺寸"
        }
    }
}

struct ImageEditorView: View {
    let asset: ImageEditorAsset
    let fallbackImage: UIImage?

    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var originalImage: UIImage?
    @State private var croppedPreview: UIImage?
    @State private var normalizedCrop = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var cropRevision = 0
    @State private var selectedTool: ImageEditorTool = .crop
    @State private var selectedAspect: ImageCropAspect = .free
    @State private var fixedAspectRatio: CGFloat?
    @State private var isAspectSheetPresented = false
    @State private var isPortraitRatio = false
    @State private var previewRotation: Angle = .zero
    @State private var previewScaleX: CGFloat = 1
    @State private var previewScaleY: CGFloat = 1
    @State private var previewOpacity: Double = 1
    @State private var isImageTransforming = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color(uiColor: .systemBackground).ignoresSafeArea()

                editorContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()

                topBar(safeAreaTop: proxy.safeAreaInsets.top)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            operationBar
        }
        .statusBarHidden(true)
        .sheet(isPresented: $isAspectSheetPresented) {
            aspectSheet
                .presentationDetents([.fraction(0.33)])
                .presentationDragIndicator(.hidden)
        }
        .task(id: asset.url) {
            if image == nil {
                image = fallbackImage
                originalImage = fallbackImage
            }
            if let loaded = loadImage(from: asset.url) {
                image = loaded
                originalImage = loaded
                isPortraitRatio = loaded.size.height > loaded.size.width
                normalizedCrop = CGRect(x: 0, y: 0, width: 1, height: 1)
                cropRevision += 1
            }
        }
    }

    @ViewBuilder
    private var editorContent: some View {
        if let image {
            if selectedTool == .crop {
                ImageCropEditorView(
                    image: image,
                    normalizedCrop: $normalizedCrop,
                    aspectRatio: fixedAspectRatio,
                    revision: cropRevision,
                    previewRotation: previewRotation,
                    previewScaleX: previewScaleX,
                    previewScaleY: previewScaleY,
                    imageOpacity: previewOpacity
                )
                .transition(.opacity)
            } else {
                Image(uiImage: croppedPreview ?? ImageEditRenderer.crop(image, to: normalizedCrop))
                    .resizable()
                    .scaledToFit()
                    .allowedDynamicRange(.high)
                    .padding(.horizontal, 18)
                    .transition(.opacity)
            }
        } else {
            ProgressView()
                .tint(.primary)
        }
    }

    private func topBar(safeAreaTop: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button("取消") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 4)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .accessibilityLabel("取消编辑")

                Spacer()

                Button("导出", action: {})
                    .buttonStyle(.plain)
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 4)
                    .glassEffect(.regular.interactive().tint(.blue), in: .capsule)
                    .accessibilityLabel("导出照片")
            }
            .padding(.horizontal, 48)
            .frame(height: max(safeAreaTop, 44))

            Spacer()
        }
        .ignoresSafeArea(.container, edges: .top)
    }

    private var operationBar: some View {
        VStack(spacing: 10) {
            if selectedTool == .crop {
                cropActions
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            toolBar
        }
        .padding(.top, selectedTool == .crop ? 8 : 12)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(Color(uiColor: .systemBackground).ignoresSafeArea(edges: .bottom))
        .animation(.easeInOut(duration: 0.2), value: selectedTool)
    }

    private var cropActions: some View {
        HStack(spacing: 22) {
            cropActionButton("rotate.right", label: "向右旋转", action: rotateRight)
            cropActionButton(
                "arrow.trianglehead.left.and.right.righttriangle.left.righttriangle.right",
                label: "水平镜像",
                action: mirrorHorizontally
            )
            cropActionButton(
                "arrow.trianglehead.up.and.down.righttriangle.up.righttriangle.down",
                label: "垂直镜像",
                action: mirrorVertically
            )
            cropActionButton("aspectratio", label: "选择裁剪比例") {
                isAspectSheetPresented = true
            }
            cropActionButton("arrow.counterclockwise", label: "重置裁剪", action: resetCrop)
        }
        .frame(height: 38)
    }

    private func cropActionButton(
        _ systemImage: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 19, weight: .medium))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(.primary)
                .frame(width: 38, height: 38)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isImageTransforming)
        .accessibilityLabel(label)
    }

    private var toolBar: some View {
        HStack(spacing: 0) {
            ForEach(ImageEditorTool.allCases) { tool in
                Button {
                    selectTool(tool)
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
                    .frame(height: 56)
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
    }

    private var aspectSheet: some View {
        VStack(spacing: 14) {
            HStack {
                Button("取消") { isAspectSheetPresented = false }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)

                Spacer()

                Text(isPortraitRatio ? "竖向" : "横向")
                    .font(.headline)

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        isPortraitRatio.toggle()
                    }
                } label: {
                    Image(systemName: "rectangle.portrait.rotate")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .accessibilityLabel("切换横向与竖向比例")
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 10) {
                ForEach(visibleFixedAspects) { aspect in
                    aspectButton(aspect)
                }
            }

            Spacer(minLength: 0)

            Button {
                applyAspect(.free)
            } label: {
                Text(ImageCropAspect.free.title(isPortrait: isPortraitRatio))
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
            }
            .buttonStyle(.plain)
            .foregroundStyle(selectedAspect == .free ? Color.primary : Color.secondary)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var visibleFixedAspects: [ImageCropAspect] {
        var values: [ImageCropAspect] = [.fourThree, .square, .threeTwo, .sixteenNine, .twentyOneTen]
        if let image {
            let originalIsPortrait = image.size.height > image.size.width
            if originalIsPortrait == isPortraitRatio {
                values.insert(.original, at: 0)
            }
        }
        return values
    }

    private func aspectButton(_ aspect: ImageCropAspect) -> some View {
        Button {
            applyAspect(aspect)
        } label: {
            Text(aspect.title(isPortrait: isPortraitRatio))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(selectedAspect == aspect ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func selectTool(_ tool: ImageEditorTool) {
        guard tool != selectedTool else { return }
        if selectedTool == .crop, tool != .crop, let image {
            croppedPreview = ImageEditRenderer.crop(image, to: normalizedCrop)
        }
        if tool == .crop {
            cropRevision += 1
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            selectedTool = tool
        }
    }

    private func applyAspect(_ aspect: ImageCropAspect) {
        guard let image else { return }
        selectedAspect = aspect

        let ratio: CGFloat?
        switch aspect {
        case .free:
            ratio = nil
        case .original:
            ratio = image.size.width / image.size.height
        default:
            guard let landscapeRatio = aspect.landscapeRatio else { return }
            ratio = isPortraitRatio ? 1 / landscapeRatio : landscapeRatio
        }

        fixedAspectRatio = ratio
        if let ratio {
            normalizedCrop = cropRect(normalizedCrop, fittedTo: ratio, imageSize: image.size)
        }
        cropRevision += 1
        isAspectSheetPresented = false
    }

    private func cropRect(_ rect: CGRect, fittedTo ratio: CGFloat, imageSize: CGSize) -> CGRect {
        var result = rect
        let currentRatio = (imageSize.width * rect.width) / (imageSize.height * rect.height)
        if currentRatio > ratio {
            let width = rect.height * imageSize.height * ratio / imageSize.width
            result.origin.x += (rect.width - width) / 2
            result.size.width = width
        } else {
            let height = rect.width * imageSize.width / ratio / imageSize.height
            result.origin.y += (rect.height - height) / 2
            result.size.height = height
        }
        return result
    }

    private func rotateRight() {
        guard let image, !isImageTransforming else { return }
        isImageTransforming = true
        withAnimation(.easeInOut(duration: 0.2)) {
            previewRotation = .degrees(90)
        }
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            self.image = ImageEditRenderer.rotateRight(image)
            normalizedCrop = CGRect(
                x: 1 - normalizedCrop.maxY,
                y: normalizedCrop.minX,
                width: normalizedCrop.height,
                height: normalizedCrop.width
            )
            if let currentRatio = fixedAspectRatio {
                fixedAspectRatio = 1 / currentRatio
            }
            isPortraitRatio.toggle()
            croppedPreview = nil
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                previewRotation = .zero
            }
            cropRevision += 1
            isImageTransforming = false
        }
    }

    private func mirrorHorizontally() {
        guard let image, !isImageTransforming else { return }
        isImageTransforming = true
        withAnimation(.easeInOut(duration: 0.18)) {
            previewScaleX = -1
        }
        Task {
            try? await Task.sleep(for: .milliseconds(180))
            self.image = ImageEditRenderer.mirrorHorizontally(image)
            normalizedCrop.origin.x = 1 - normalizedCrop.maxX
            croppedPreview = nil
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                previewScaleX = 1
            }
            cropRevision += 1
            isImageTransforming = false
        }
    }

    private func mirrorVertically() {
        guard let image, !isImageTransforming else { return }
        isImageTransforming = true
        withAnimation(.easeInOut(duration: 0.18)) {
            previewScaleY = -1
        }
        Task {
            try? await Task.sleep(for: .milliseconds(180))
            self.image = ImageEditRenderer.mirrorVertically(image)
            normalizedCrop.origin.y = 1 - normalizedCrop.maxY
            croppedPreview = nil
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                previewScaleY = 1
            }
            cropRevision += 1
            isImageTransforming = false
        }
    }

    private func resetCrop() {
        guard let originalImage, !isImageTransforming else { return }
        isImageTransforming = true
        withAnimation(.easeOut(duration: 0.12)) {
            previewOpacity = 0
        }
        Task {
            try? await Task.sleep(for: .milliseconds(120))
            image = originalImage
            normalizedCrop = CGRect(x: 0, y: 0, width: 1, height: 1)
            selectedAspect = .free
            fixedAspectRatio = nil
            isPortraitRatio = originalImage.size.height > originalImage.size.width
            croppedPreview = nil
            cropRevision += 1
            withAnimation(.easeIn(duration: 0.2)) {
                previewOpacity = 1
            }
            isImageTransforming = false
        }
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
