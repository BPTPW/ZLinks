//
//  ImageEditorView.swift
//  ZLinks
//

import ImageIO
import CoreImage
import CoreImage.CIFilterBuiltins
import MetalKit
import SwiftUI
import UIKit

struct ImageEditorAsset: Identifiable {
    let id = UUID()
    let url: URL
}

private extension URL {
    var isRawImage: Bool {
        ["nef", "nrw", "arw", "cr2", "cr3", "dng", "raf", "orf", "rw2"].contains(pathExtension.lowercased())
    }
}

private struct RawAdjustmentDefaults: Equatable {
    let temperature: Float
    let tint: Float
}

private struct AdjustmentPreview: UIViewRepresentable {
    let image: UIImage
    let sourceURL: URL?
    let recipe: EditRecipe
    let rawDefaults: RawAdjustmentDefaults?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator.device)
        view.delegate = context.coordinator
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.framebufferOnly = false
        view.autoResizeDrawable = true
        view.colorPixelFormat = .bgra8Unorm
        view.contentMode = .scaleAspectFit
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.update(
            image: image,
            sourceURL: sourceURL,
            recipe: recipe,
            rawDefaults: rawDefaults
        )
        view.setNeedsDisplay()
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        let device: MTLDevice = MTLCreateSystemDefaultDevice()!
        let commandQueue: MTLCommandQueue
        let context: CIContext
        private var image: UIImage?
        private var sourceURL: URL?
        private var recipe = EditRecipe()
        private var rawDefaults: RawAdjustmentDefaults?
        private var cachedUIImage: UIImage?
        private var cachedURL: URL?
        private var cachedSourceImage: CIImage?

        override init() {
            commandQueue = device.makeCommandQueue()!
            context = CIContext(mtlDevice: device, options: [CIContextOption.cacheIntermediates: true])
        }

        func update(
            image: UIImage,
            sourceURL: URL?,
            recipe: EditRecipe,
            rawDefaults: RawAdjustmentDefaults?
        ) {
            if cachedUIImage !== image || cachedURL != sourceURL {
                cachedUIImage = image
                cachedURL = sourceURL
                cachedSourceImage = nil
            }
            self.image = image
            self.sourceURL = sourceURL
            self.recipe = recipe
            self.rawDefaults = rawDefaults
        }

        func draw(in view: MTKView) {
            guard let drawable = view.currentDrawable,
                  let commandBuffer = commandQueue.makeCommandBuffer(),
                  let image
            else { return }

            let drawableSize = CGSize(width: drawable.texture.width, height: drawable.texture.height)
            if cachedSourceImage == nil {
                cachedSourceImage = ImageEditPipeline.sourceImage(
                    uiImage: image,
                    sourceURL: sourceURL,
                    maximumPixelSize: max(drawableSize.width, drawableSize.height) * 1.25
                )
            }
            guard let sourceImage = cachedSourceImage else { return }
            let adjusted = ImageEditPipeline.adjustedImage(
                sourceImage,
                recipe: recipe,
                rawDefaults: rawDefaults
            )
            let output = ImageEditPipeline.previewImage(adjusted, drawableSize: drawableSize)

            context.render(
                output,
                to: drawable.texture,
                commandBuffer: commandBuffer,
                bounds: CGRect(origin: .zero, size: drawableSize),
                colorSpace: CGColorSpaceCreateDeviceRGB()
            )
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    }
}

private enum ImageEditPipeline {
    static func sourceImage(uiImage: UIImage, sourceURL: URL?, maximumPixelSize: CGFloat) -> CIImage? {
        if let sourceURL, sourceURL.isRawImage, let raw = CIRAWFilter(imageURL: sourceURL) {
            raw.isDraftModeEnabled = true
            let nativeLongEdge = max(raw.nativeSize.width, raw.nativeSize.height)
            raw.scaleFactor = Float(min(1, maximumPixelSize / max(nativeLongEdge, 1)))
            if let output = raw.outputImage { return output }
        }
        return CIImage(image: uiImage, options: [.applyOrientationProperty: true])
    }

    static func adjustedImage(
        _ image: CIImage,
        recipe: EditRecipe,
        rawDefaults: RawAdjustmentDefaults?
    ) -> CIImage {
        var result = image

        if abs(recipe.exposure) > 0.001 {
            let filter = CIFilter.exposureAdjust()
            filter.inputImage = result
            filter.ev = recipe.exposure / 50
            result = filter.outputImage ?? result
        }

        let controls = CIFilter.colorControls()
        controls.inputImage = result
        controls.brightness = recipe.brightness / 100
        controls.contrast = max(0.25, 1 + recipe.contrast / 100)
        controls.saturation = 1
        result = controls.outputImage ?? result

        if abs(recipe.contrastBase) > 0.001 {
            let curve = CIFilter.toneCurve()
            curve.inputImage = result
            let amount = CGFloat(recipe.contrastBase) / 100 * 0.15
            curve.point0 = CGPoint(x: 0, y: 0)
            curve.point1 = CGPoint(x: 0.25, y: 0.25 - amount)
            curve.point2 = CGPoint(x: 0.5, y: 0.5)
            curve.point3 = CGPoint(x: 0.75, y: 0.75 + amount)
            curve.point4 = CGPoint(x: 1, y: 1)
            result = curve.outputImage ?? result
        }

        if abs(recipe.highlights) > 0.001 || abs(recipe.shadows) > 0.001 {
            let filter = CIFilter.highlightShadowAdjust()
            filter.inputImage = result
            filter.highlightAmount = max(0, min(1, 1 - recipe.highlights / 100))
            filter.shadowAmount = max(-1, min(1, recipe.shadows / 100))
            result = filter.outputImage ?? result
        }

        // Whites and blacks are endpoint tonal-range controls rather than
        // white/black point clipping. Moving the inner quarter points makes
        // both directions useful while keeping most midtones unchanged.
        if abs(recipe.whites) > 0.001 || abs(recipe.blacks) > 0.001 {
            let curve = CIFilter.toneCurve()
            curve.inputImage = result

            let whites = CGFloat(max(-100, min(100, recipe.whites))) / 100
            let blacks = CGFloat(max(-100, min(100, recipe.blacks))) / 100
            let blackEndpoint = max(0, blacks) * 0.08
            let whiteEndpoint = 1 + min(0, whites) * 0.08

            curve.point0 = CGPoint(x: 0, y: blackEndpoint)
            curve.point1 = CGPoint(x: 0.25, y: 0.25 + blacks * 0.18)
            curve.point2 = CGPoint(x: 0.5, y: 0.5)
            curve.point3 = CGPoint(x: 0.75, y: 0.75 + whites * 0.18)
            curve.point4 = CGPoint(x: 1, y: whiteEndpoint)
            result = curve.outputImage ?? result
        }

        let neutralTemperature = rawDefaults?.temperature ?? 6500
        let neutralTint = rawDefaults?.tint ?? 0
        let targetTemperature = rawDefaults == nil ? 6500 + recipe.temperature * 20 : recipe.temperature
        let targetTint = recipe.tint
        if abs(targetTemperature - neutralTemperature) > 0.001 || abs(targetTint - neutralTint) > 0.001 {
            let filter = CIFilter.temperatureAndTint()
            filter.inputImage = result
            filter.neutral = CIVector(x: CGFloat(neutralTemperature), y: CGFloat(neutralTint))
            filter.targetNeutral = CIVector(x: CGFloat(targetTemperature), y: CGFloat(targetTint))
            result = filter.outputImage ?? result
        }

        if abs(recipe.saturation) > 0.001 {
            let filter = CIFilter.vibrance()
            filter.inputImage = result
            filter.amount = max(-1, min(1, recipe.saturation / 100))
            result = filter.outputImage ?? result
        }
        return result
    }

    static func previewImage(_ image: CIImage, drawableSize: CGSize) -> CIImage {
        let bounds = CGRect(origin: .zero, size: drawableSize).integral
        let extent = image.extent.integral
        guard extent.width > 0, extent.height > 0 else { return image }
        let scale = min(bounds.width / extent.width, bounds.height / extent.height)
        let targetSize = CGSize(
            width: floor(extent.width * scale),
            height: floor(extent.height * scale)
        )
        let target = CGRect(
            x: floor((bounds.width - targetSize.width) / 2),
            y: floor((bounds.height - targetSize.height) / 2),
            width: targetSize.width,
            height: targetSize.height
        )
        let normalized = image
            .clampedToExtent()
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        let scaled = normalized.transformed(by: CGAffineTransform(
            scaleX: target.width / extent.width,
            y: target.height / extent.height
        ))
        let fitted = scaled
            .transformed(by: CGAffineTransform(translationX: target.minX, y: target.minY))
            .cropped(to: target)
        let background = CIImage(color: .clear).cropped(to: bounds)
        return fitted.composited(over: background).cropped(to: bounds)
    }
}

/// The complete edit state. Values exposed to the controls use the familiar
/// -100...100 range; the renderer maps them to Core Image's native ranges.
struct EditRecipe: Codable, Equatable {
    var exposure: Float = 0
    var brightness: Float = 0
    var contrast: Float = 0
    var contrastBase: Float = 0
    var whites: Float = 0
    var highlights: Float = 0
    var shadows: Float = 0
    var blacks: Float = 0
    var temperature: Float = 0
    var tint: Float = 0
    var saturation: Float = 0
}

private enum AdjustmentSection: String, CaseIterable, Identifiable {
    case brightness, advancedBrightness, color

    var id: String { rawValue }
    var title: String {
        switch self {
        case .brightness: return "亮度"
        case .advancedBrightness: return "高级亮度"
        case .color: return "颜色"
        }
    }
    var systemImage: String {
        switch self {
        case .brightness: return "lightbulb.max"
        case .advancedBrightness: return "sun.max"
        case .color: return "thermometer.sun"
        }
    }
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
    @State private var editRecipe = EditRecipe()
    @State private var rawAdjustmentDefaults: RawAdjustmentDefaults?
    @State private var selectedAdjustmentSection: AdjustmentSection = .brightness
    @State private var usesRawSource = false

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
                usesRawSource = asset.url.isRawImage
                rawAdjustmentDefaults = asset.url.isRawImage ? rawDefaults(for: asset.url) : nil
                editRecipe = EditRecipe()
                if let rawAdjustmentDefaults {
                    editRecipe.temperature = rawAdjustmentDefaults.temperature
                    editRecipe.tint = rawAdjustmentDefaults.tint
                }
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
            } else if selectedTool == .adjustments {
                AdjustmentPreview(
                    image: croppedPreview ?? image,
                    sourceURL: usesRawSource && croppedPreview == nil ? asset.url : nil,
                    recipe: editRecipe,
                    rawDefaults: rawAdjustmentDefaults
                )
                .padding(.horizontal, 18)
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
            } else if selectedTool == .adjustments {
                adjustmentPanel
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

    private var adjustmentPanel: some View {
        VStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(AdjustmentSection.allCases) { section in
                        Button {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                selectedAdjustmentSection = section
                            }
                        } label: {
                            Label(section.title, systemImage: section.systemImage)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(selectedAdjustmentSection == section ? .white : .primary)
                                .padding(.horizontal, 13)
                                .frame(height: 36)
                                .background {
                                    Capsule()
                                        .fill(selectedAdjustmentSection == section ? Color.blue : Color.clear)
                                }
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .capsule)
                        .accessibilityAddTraits(selectedAdjustmentSection == section ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 2)
            }

            VStack(spacing: 7) {
                switch selectedAdjustmentSection {
                case .brightness:
                    adjustmentRow("曝光", value: $editRecipe.exposure)
                    adjustmentRow("亮度", value: $editRecipe.brightness)
                    adjustmentRow("对比度", value: $editRecipe.contrast)
                    adjustmentRow("对比度基准", value: $editRecipe.contrastBase)
                case .advancedBrightness:
                    adjustmentRow("白色", value: $editRecipe.whites)
                    adjustmentRow("高光", value: $editRecipe.highlights)
                    adjustmentRow("阴影", value: $editRecipe.shadows)
                    adjustmentRow("黑色", value: $editRecipe.blacks)
                case .color:
                    adjustmentRow(
                        "色温",
                        value: $editRecipe.temperature,
                        range: rawAdjustmentDefaults == nil ? -100...100 : 2000...50000,
                        defaultValue: rawAdjustmentDefaults?.temperature ?? 0,
                        showsSign: rawAdjustmentDefaults == nil,
                        suffix: rawAdjustmentDefaults == nil ? "" : "K"
                    )
                    adjustmentRow(
                        "色调",
                        value: $editRecipe.tint,
                        range: rawAdjustmentDefaults == nil ? -100...100 : -150...150,
                        defaultValue: rawAdjustmentDefaults?.tint ?? 0
                    )
                    adjustmentRow("饱和度", value: $editRecipe.saturation)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 2)
        .frame(maxHeight: 258)
    }

    private func adjustmentRow(
        _ title: String,
        value: Binding<Float>,
        range: ClosedRange<Float> = -100...100,
        defaultValue: Float = 0,
        showsSign: Bool = true,
        suffix: String = ""
    ) -> some View {
        let isModified = abs(value.wrappedValue - defaultValue) > 0.001
        return HStack(spacing: 9) {
            Button {
                value.wrappedValue = defaultValue
            } label: {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .frame(width: 74, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("重置\(title)")

            Slider(value: value, in: range, step: 1)
                .tint(isModified ? .orange : .blue)
                .accessibilityLabel(title)

            Text(Self.displayValue(value.wrappedValue, showsSign: showsSign) + suffix)
                .font(.system(size: 12, weight: .regular, design: .rounded).monospacedDigit())
                .foregroundStyle(isModified ? .orange : .secondary)
                .frame(width: suffix.isEmpty ? 42 : 52, alignment: .trailing)
                .contentShape(Rectangle())
                .onTapGesture { value.wrappedValue = defaultValue }
        }
        .frame(height: 31)
    }

    private static func displayValue(_ value: Float, showsSign: Bool = true) -> String {
        let rounded = Int(value.rounded())
        guard showsSign else { return "\(rounded)" }
        return rounded > 0 ? "+\(rounded)" : "\(rounded)"
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
            let crop = normalizedCrop.standardized
            let isFullImage = crop.minX <= 0.0001 && crop.minY <= 0.0001
                && crop.maxX >= 0.9999 && crop.maxY >= 0.9999
            croppedPreview = isFullImage ? nil : ImageEditRenderer.crop(image, to: crop)
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
            usesRawSource = false
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
            usesRawSource = false
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
            usesRawSource = false
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
            usesRawSource = asset.url.isRawImage
            editRecipe = EditRecipe()
            if let rawAdjustmentDefaults {
                editRecipe.temperature = rawAdjustmentDefaults.temperature
                editRecipe.tint = rawAdjustmentDefaults.tint
            }
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

    private func rawDefaults(for url: URL) -> RawAdjustmentDefaults? {
        guard url.isRawImage, let raw = CIRAWFilter(imageURL: url) else { return nil }
        return RawAdjustmentDefaults(
            temperature: raw.neutralTemperature > 0 ? raw.neutralTemperature : 6500,
            tint: raw.neutralTint
        )
    }
}
