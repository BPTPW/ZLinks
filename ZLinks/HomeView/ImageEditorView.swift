//
//  ImageEditorView.swift
//  ZLinks
//

import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import MetalKit
import Photos
import SwiftUI
import UIKit

struct ImageEditorAsset: Identifiable {
    let id = UUID()
    let url: URL
    let filename: String
    let thumbnailHandle: UInt32?
    let thumbnailData: Data?

    init(
        url: URL,
        filename: String? = nil,
        thumbnailHandle: UInt32? = nil,
        thumbnailData: Data? = nil
    ) {
        self.url = url
        self.filename = filename ?? url.lastPathComponent
        self.thumbnailHandle = thumbnailHandle
        self.thumbnailData = thumbnailData
    }
}

private enum ImageEditorExportError: LocalizedError {
    case photoLibraryAccessDenied
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .photoLibraryAccessDenied:
            return "没有相册写入权限。"
        case .renderFailed:
            return "无法按照编辑数据导出 JPEG。"
        }
    }
}

private extension URL {
    nonisolated var isRawImage: Bool {
        ["nef", "nrw", "arw", "cr2", "cr3", "dng", "raf", "orf", "rw2"].contains(pathExtension.lowercased())
    }
}

struct RawAdjustmentDefaults: Sendable {
    let temperature: Float
    let tint: Float

    nonisolated init(temperature: Float, tint: Float) {
        self.temperature = temperature
        self.tint = tint
    }
}

private struct HistogramData: Equatable, Sendable {
    nonisolated static let empty = HistogramData(red: [], green: [], blue: [], luminance: [])

    let red: [Float]
    let green: [Float]
    let blue: [Float]
    let luminance: [Float]

    var isEmpty: Bool { red.isEmpty }
}

struct CurvePoint: Codable, Equatable, Sendable {
    var x: Float
    var y: Float

    nonisolated static let identity: [CurvePoint] = [
        CurvePoint(x: 0, y: 0),
        CurvePoint(x: 1, y: 1)
    ]
}

extension CurvePoint {
    nonisolated static func interpolatedValue(at x: Float, in points: [CurvePoint]) -> Float {
        let sorted = points.sorted { $0.x < $1.x }
        guard let first = sorted.first, let last = sorted.last, sorted.count > 1 else {
            return sorted.first?.y ?? x
        }
        if x <= first.x { return max(0, min(1, first.y)) }
        if x >= last.x { return max(0, min(1, last.y)) }

        for index in 1..<sorted.count {
            let right = sorted[index]
            guard x <= right.x else { continue }
            let left = sorted[index - 1]
            let previous = index > 1 ? sorted[index - 2] : left
            let next = index + 1 < sorted.count ? sorted[index + 1] : right
            let span = max(right.x - left.x, 0.0001)
            let t = min(1, max(0, (x - left.x) / span))
            let t2 = t * t
            let t3 = t2 * t
            let leftSlope = (right.y - previous.y) / max(right.x - previous.x, 0.0001)
            let rightSlope = (next.y - left.y) / max(next.x - left.x, 0.0001)
            let h00 = 2 * t3 - 3 * t2 + 1
            let h10 = t3 - 2 * t2 + t
            let h01 = -2 * t3 + 3 * t2
            let h11 = t3 - t2
            let value = h00 * left.y + h10 * span * leftSlope
                + h01 * right.y + h11 * span * rightSlope
            return max(0, min(1, value))
        }
        return x
    }
}

enum CurveChannel: CaseIterable, Identifiable {
    case rgb
    case red
    case green
    case blue

    var id: Self { self }

    var title: String {
        switch self {
        case .rgb: return "RGB"
        case .red: return "红"
        case .green: return "绿"
        case .blue: return "蓝"
        }
    }

    var systemColor: Color {
        switch self {
        case .rgb: return .primary
        case .red: return .red
        case .green: return .green
        case .blue: return .blue
        }
    }
}

private enum HistogramChannel: CaseIterable {
    case red
    case green
    case blue
    case luminance
    case all

    var title: String {
        switch self {
        case .red: return "红"
        case .green: return "绿"
        case .blue: return "蓝"
        case .luminance: return "RGB"
        case .all: return "全部"
        }
    }

    var next: HistogramChannel {
        switch self {
        case .all: return .red
        case .red: return .green
        case .green: return .blue
        case .blue: return .luminance
        case .luminance: return .all
        }
    }
}

private struct HistogramRequest: Equatable {
    let imageID: ObjectIdentifier
    let revision: Int
    let recipe: EditRecipe
    let sourcePath: String?
}

private struct HistogramCalculationInput: @unchecked Sendable {
    let image: UIImage
    let sourceURL: URL?
    let recipe: EditRecipe
    let rawDefaults: RawAdjustmentDefaults?
}

private actor HistogramProcessor {
    private var pendingInput: HistogramCalculationInput?
    private var isProcessing = false

    func submit(
        _ input: HistogramCalculationInput,
        onResult: @MainActor @Sendable @escaping (HistogramData) -> Void
    ) async {
        pendingInput = input
        guard !isProcessing else { return }

        isProcessing = true
        while let nextInput = pendingInput {
            pendingInput = nil
            let result = HistogramCalculator.calculate(
                image: nextInput.image,
                sourceURL: nextInput.sourceURL,
                recipe: nextInput.recipe,
                rawDefaults: nextInput.rawDefaults
            )
            await onResult(result)
        }
        isProcessing = false
    }
}

private struct HistogramOverlay: View {
    let image: UIImage
    let sourceURL: URL?
    let recipe: EditRecipe
    let rawDefaults: RawAdjustmentDefaults?
    let revision: Int

    @State private var data = HistogramData.empty
    @State private var channel: HistogramChannel = .all
    @State private var isLarge = false
    @State private var processor = HistogramProcessor()

    private var canvasSize: CGSize {
        isLarge
            ? CGSize(width: 224, height: 142)
            : CGSize(width: 148, height: 92)
    }

    private var request: HistogramRequest {
        HistogramRequest(
            imageID: ObjectIdentifier(image),
            revision: revision,
            recipe: recipe,
            sourcePath: sourceURL?.path
        )
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Button {
                channel = channel.next
            } label: {
                HistogramCanvas(data: data, channel: channel)
                    .frame(width: canvasSize.width, height: canvasSize.height)
                    .padding(8)
                    .background(.black.opacity(0.64), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(.white.opacity(0.16), lineWidth: 0.5)
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("切换直方图通道")
            .accessibilityValue(channel.title)

            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isLarge.toggle()
                }
            } label: {
                Image(systemName: isLarge
                    ? "arrow.down.right.and.arrow.up.left"
                    : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isLarge ? "缩小直方图" : "放大直方图")
            .padding(1)
        }
        .task(id: request) {
            let taskRequest = request
            let input = HistogramCalculationInput(
                image: image,
                sourceURL: sourceURL,
                recipe: recipe,
                rawDefaults: rawDefaults
            )
            await processor.submit(input) { result in
                guard taskRequest == request else { return }
                data = result
            }
        }
    }
}

private struct HistogramCanvas: View {
    let data: HistogramData
    let channel: HistogramChannel

    var body: some View {
        Canvas { context, size in
            guard !data.isEmpty else { return }

            let plotRect = CGRect(x: 0, y: 0, width: size.width, height: size.height)
            let curves: [(values: [Float], color: Color)]
            switch channel {
            case .red:
                curves = [(data.red, .red)]
            case .green:
                curves = [(data.green, .green)]
            case .blue:
                curves = [(data.blue, .blue)]
            case .luminance:
                curves = [(data.luminance, .white)]
            case .all:
                curves = [(data.red, .red), (data.green, .green), (data.blue, .blue), (data.luminance, .white)]
            }

            let populatedBins = curves
                .flatMap(\.values)
                .filter { $0 > 0 }
                .sorted()
            let scaleIndex = Int((Double(max(populatedBins.count - 1, 0)) * 0.99).rounded(.down))
            let maximum = max(populatedBins.isEmpty ? 1 : populatedBins[scaleIndex], 0.000001)
            for curve in curves {
                var path = Path()
                for (index, value) in curve.values.enumerated() {
                    let x = plotRect.minX + plotRect.width * CGFloat(index) / CGFloat(max(curve.values.count - 1, 1))
                    let normalized = min(1, CGFloat(value / maximum))
                    let y = plotRect.maxY - normalized * plotRect.height
                    if index == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
                context.stroke(path, with: .color(curve.color), style: StrokeStyle(lineWidth: 1.55, lineCap: .round, lineJoin: .round))
            }
        }
        .accessibilityHidden(true)
    }
}

private struct CurveAdjustmentPanel: View {
    @Binding var recipe: EditRecipe
    @Binding var selectedChannel: CurveChannel
    let image: UIImage
    let sourceURL: URL?
    let rawDefaults: RawAdjustmentDefaults?
    let revision: Int

    @State private var histogram = HistogramData.empty

    private var histogramRequest: HistogramRequest {
        HistogramRequest(
            imageID: ObjectIdentifier(image),
            revision: revision,
            recipe: recipe.withoutCurves,
            sourcePath: sourceURL?.path
        )
    }

    private var points: Binding<[CurvePoint]> {
        Binding(
            get: { recipe.curve(for: selectedChannel) },
            set: { newValue in
                switch selectedChannel {
                case .rgb: recipe.curveRGB = newValue
                case .red: recipe.curveRed = newValue
                case .green: recipe.curveGreen = newValue
                case .blue: recipe.curveBlue = newValue
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 13) {
                ForEach(CurveChannel.allCases) { channel in
                    Button {
                        withAnimation(.easeInOut(duration: 0.12)) {
                            selectedChannel = channel
                        }
                    } label: {
                        Circle()
                            .fill(channel == .rgb ? Color.clear : channel.systemColor.opacity(0.16))
                            .frame(width: 29, height: 29)
                            .overlay {
                                Circle()
                                    .stroke(channel.systemColor, lineWidth: channel == selectedChannel ? 2.8 : 1.5)
                            }
                            .overlay {
                                if channel == selectedChannel {
                                    Circle().stroke(Color.blue.opacity(0.8), lineWidth: 1).padding(-4)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("曲线\(channel.title)通道")
                    .accessibilityAddTraits(channel == selectedChannel ? .isSelected : [])
                }

                Text(selectedChannel.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
            }

            CurveEditor(points: points, histogram: histogram, channel: selectedChannel)
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .padding(.horizontal, 10)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .stroke(.primary.opacity(0.16), lineWidth: 0.7)
                }
        }
        .task(id: histogramRequest) {
            let request = histogramRequest
            let input = HistogramCalculationInput(
                image: image,
                sourceURL: sourceURL,
                recipe: request.recipe,
                rawDefaults: rawDefaults
            )
            let result = await Task.detached(priority: .utility) {
                HistogramCalculator.calculate(
                    image: input.image,
                    sourceURL: input.sourceURL,
                    recipe: input.recipe,
                    rawDefaults: input.rawDefaults
                )
            }.value
            guard !Task.isCancelled, request == histogramRequest else { return }
            histogram = result
        }
    }
}

private struct CurveEditor: View {
    @Binding var points: [CurvePoint]
    let histogram: HistogramData
    let channel: CurveChannel

    @State private var activeIndex: Int?

    private var histogramValues: [Float] {
        switch channel {
        case .rgb: return histogram.luminance
        case .red: return histogram.red
        case .green: return histogram.green
        case .blue: return histogram.blue
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                Canvas { context, size in
                    drawGrid(context: &context, size: size)
                    drawHistogram(context: &context, size: size)
                    drawCurve(context: &context, size: size)
                }

                Color.clear
                    .contentShape(Rectangle())
                    .gesture(dragGesture(side: side))
                    .simultaneousGesture(tapGesture(side: side))
            }
        }
        .background(Color(uiColor: .secondarySystemBackground).opacity(0.72))
    }

    private func drawGrid(context: inout GraphicsContext, size: CGSize) {
        var path = Path()
        for step in 1..<4 {
            let position = size.width * CGFloat(step) / 4
            path.move(to: CGPoint(x: position, y: 0))
            path.addLine(to: CGPoint(x: position, y: size.height))
            path.move(to: CGPoint(x: 0, y: position))
            path.addLine(to: CGPoint(x: size.width, y: position))
        }
        context.stroke(path, with: .color(.primary.opacity(0.16)), style: StrokeStyle(lineWidth: 0.55))
    }

    private func drawHistogram(context: inout GraphicsContext, size: CGSize) {
        guard !histogramValues.isEmpty else { return }
        let maximum = histogramValues.max() ?? 1
        guard maximum > 0 else { return }
        var path = Path()
        path.move(to: CGPoint(x: 0, y: size.height))
        for (index, value) in histogramValues.enumerated() {
            let x = size.width * CGFloat(index) / CGFloat(max(histogramValues.count - 1, 1))
            let y = size.height - CGFloat(value / maximum) * size.height * 0.92
            path.addLine(to: CGPoint(x: x, y: y))
        }
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.closeSubpath()
        context.fill(path, with: .color(channel.systemColor.opacity(0.19)))
    }

    private func drawCurve(context: inout GraphicsContext, size: CGSize) {
        let sorted = points.sorted { $0.x < $1.x }
        guard sorted.count > 1 else { return }
        var line = Path()
        let sampleCount = max(48, (sorted.count - 1) * 24)
        for index in 0...sampleCount {
            let x = Float(index) / Float(sampleCount)
            let y = CurvePoint.interpolatedValue(at: x, in: sorted)
            let location = CGPoint(x: CGFloat(x) * size.width, y: (1 - CGFloat(y)) * size.height)
            if index == 0 {
                line.move(to: location)
            } else {
                line.addLine(to: location)
            }
        }
        context.stroke(line, with: .color(channel.systemColor), style: StrokeStyle(lineWidth: 2.1, lineCap: .round, lineJoin: .round))

        for point in sorted {
            let location = CGPoint(x: CGFloat(point.x) * size.width, y: (1 - CGFloat(point.y)) * size.height)
            context.fill(Path(ellipseIn: CGRect(x: location.x - 5, y: location.y - 5, width: 10, height: 10)), with: .color(.white))
            context.stroke(Path(ellipseIn: CGRect(x: location.x - 5, y: location.y - 5, width: 10, height: 10)), with: .color(channel.systemColor), style: StrokeStyle(lineWidth: 1.6))
        }
    }

    private func dragGesture(side: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                let location = normalizedLocation(value.location, side: side)
                if activeIndex == nil {
                    let nearest = points.enumerated().min {
                        distance(to: $0.element, from: location, side: side) < distance(to: $1.element, from: location, side: side)
                    }
                    if let nearest, distance(to: nearest.element, from: location, side: side) < 24 {
                        activeIndex = nearest.offset
                    } else {
                        let newPoint = CurvePoint(x: location.x, y: location.y)
                        points.append(newPoint)
                        points.sort { $0.x < $1.x }
                        activeIndex = points.firstIndex(of: newPoint)
                    }
                }
                guard let activeIndex, points.indices.contains(activeIndex) else { return }
                var point = points[activeIndex]
                let lower = activeIndex == 0 ? 0 : points[activeIndex - 1].x + 0.004
                let upper = activeIndex == points.count - 1 ? 1 : points[activeIndex + 1].x - 0.004
                point.x = min(upper, max(lower, location.x))
                point.y = location.y
                points[activeIndex] = point
            }
            .onEnded { _ in
                activeIndex = nil
            }
    }

    private func tapGesture(side: CGFloat) -> some Gesture {
        SpatialTapGesture(count: 2)
            .onEnded { value in
                let location = normalizedLocation(value.location, side: side)
                guard let nearest = points.enumerated().min(by: {
                    distance(to: $0.element, from: location, side: side) < distance(to: $1.element, from: location, side: side)
                }), nearest.offset > 0, nearest.offset < points.count - 1,
                distance(to: nearest.element, from: location, side: side) < 24 else { return }
                activeIndex = nil
                points.remove(at: nearest.offset)
            }
            .exclusively(before: SpatialTapGesture(count: 1).onEnded { value in
                let location = normalizedLocation(value.location, side: side)
                let isNearExistingPoint = points.contains {
                    distance(to: $0, from: location, side: side) < 24
                }
                guard !isNearExistingPoint else { return }
                points.append(CurvePoint(x: location.x, y: location.y))
                points.sort { $0.x < $1.x }
            })
    }

    private func normalizedLocation(_ location: CGPoint, side: CGFloat) -> CurvePoint {
        CurvePoint(
            x: Float(min(1, max(0, location.x / max(side, 1)))),
            y: Float(min(1, max(0, 1 - location.y / max(side, 1))))
        )
    }

    private func distance(to point: CurvePoint, from location: CurvePoint, side: CGFloat) -> CGFloat {
        let dx = CGFloat(point.x - location.x) * side
        let dy = CGFloat(point.y - location.y) * side
        return hypot(dx, dy)
    }
}

private enum HistogramCalculator {
    // CIContext is thread-safe and reusing it avoids initialization on every slider tick.
    private nonisolated static let context = CIContext(options: [.cacheIntermediates: false])

    nonisolated static func calculate(
        image: UIImage,
        sourceURL: URL?,
        recipe: EditRecipe,
        rawDefaults: RawAdjustmentDefaults?
    ) -> HistogramData {
        guard let source = ImageEditPipeline.sourceImage(
            uiImage: image,
            sourceURL: sourceURL,
            maximumPixelSize: 1024
        ) else { return .empty }

        let adjusted = ImageEditPipeline.adjustedImage(source, recipe: recipe, rawDefaults: rawDefaults)
        let extent = adjusted.extent.integral
        guard extent.width > 0, extent.height > 0 else { return .empty }

        let sampleLongEdge: CGFloat = 512
        let scale = min(1, sampleLongEdge / max(extent.width, extent.height))
        let width = max(1, Int((extent.width * scale).rounded(.up)))
        let height = max(1, Int((extent.height * scale).rounded(.up)))
        let sampleBounds = CGRect(x: 0, y: 0, width: width, height: height)
        let sampledImage = adjusted
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .cropped(to: sampleBounds)

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            context.render(
                sampledImage,
                toBitmap: baseAddress,
                rowBytes: width * 4,
                bounds: sampleBounds,
                format: .RGBA8,
                colorSpace: CGColorSpaceCreateDeviceRGB()
            )
        }

        let count = 256
        var red = [Float](repeating: 0, count: count)
        var green = red
        var blue = red
        var luminance = red
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = pixels[offset + 3]
            guard alpha > 0 else { continue }

            let redValue = pixels[offset]
            let greenValue = pixels[offset + 1]
            let blueValue = pixels[offset + 2]
            let luminanceValue = Int(
                (Float(redValue) * 0.2126
                    + Float(greenValue) * 0.7152
                    + Float(blueValue) * 0.0722).rounded()
            )

            let weight = Float(alpha) / 255
            red[Int(redValue)] += weight
            green[Int(greenValue)] += weight
            blue[Int(blueValue)] += weight
            luminance[min(255, luminanceValue)] += weight
        }
        return HistogramData(red: red, green: green, blue: blue, luminance: luminance)
    }
}

struct AdjustmentPreview: UIViewRepresentable {
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

enum ImageEditPipeline {
    nonisolated static func sourceImage(uiImage: UIImage, sourceURL: URL?, maximumPixelSize: CGFloat) -> CIImage? {
        if let sourceURL, sourceURL.isRawImage, let raw = CIRAWFilter(imageURL: sourceURL) {
            raw.isDraftModeEnabled = true
            let nativeLongEdge = max(raw.nativeSize.width, raw.nativeSize.height)
            raw.scaleFactor = Float(min(1, maximumPixelSize / max(nativeLongEdge, 1)))
            if let output = raw.outputImage { return output }
        }
        return CIImage(image: uiImage, options: [.applyOrientationProperty: true])
    }

    nonisolated static func adjustedImage(
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
            // Core Image's highlightAmount only supports reducing highlights
            // from its identity value of 1. Positive values are lifted below.
            let highlights = recipe.highlights / 100
            filter.highlightAmount = highlights < 0
                ? max(0.3, 1 + highlights * 0.7)
                : 1
            filter.shadowAmount = max(-1, min(1, recipe.shadows / 100))
            result = filter.outputImage ?? result

            if recipe.highlights > 0.001 {
                let curve = CIFilter.toneCurve()
                curve.inputImage = result
                let amount = CGFloat(min(100, recipe.highlights)) / 100 * 0.12
                curve.point0 = CGPoint(x: 0, y: 0)
                curve.point1 = CGPoint(x: 0.25, y: 0.25)
                curve.point2 = CGPoint(x: 0.5, y: 0.5)
                curve.point3 = CGPoint(x: 0.75, y: 0.75 + amount)
                curve.point4 = CGPoint(x: 1, y: 1 + amount * 0.35)
                result = curve.outputImage ?? result
            }
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

        if recipe.hasCurveAdjustments {
            let dimension = 32
            var cube = [Float]()
            cube.reserveCapacity(dimension * dimension * dimension * 4)
            let rgb = Self.curveLUT(recipe.curveRGB)
            let red = Self.curveLUT(recipe.curveRed)
            let green = Self.curveLUT(recipe.curveGreen)
            let blue = Self.curveLUT(recipe.curveBlue)

            // Core Image's cube layout uses red as the fastest-changing
            // component and stores RGBA float values for every entry.
            for blueIndex in 0..<dimension {
                let blueInput = Float(blueIndex) / Float(dimension - 1)
                for greenIndex in 0..<dimension {
                    let greenInput = Float(greenIndex) / Float(dimension - 1)
                    for redIndex in 0..<dimension {
                        let redInput = Float(redIndex) / Float(dimension - 1)
                        let redValue = rgb[Int((redInput * 255).rounded())]
                        let greenValue = rgb[Int((greenInput * 255).rounded())]
                        let blueValue = rgb[Int((blueInput * 255).rounded())]
                        cube.append(red[Int((redValue * 255).rounded())])
                        cube.append(green[Int((greenValue * 255).rounded())])
                        cube.append(blue[Int((blueValue * 255).rounded())])
                        cube.append(1)
                    }
                }
            }

            let cubeFilter = CIFilter.colorCubeWithColorSpace()
            cubeFilter.inputImage = result
            cubeFilter.cubeDimension = Float(dimension)
            cubeFilter.cubeData = cube.withUnsafeBufferPointer { Data(buffer: $0) }
            cubeFilter.colorSpace = CGColorSpaceCreateDeviceRGB()
            result = cubeFilter.outputImage ?? result
        }
        return result
    }

    private nonisolated static func curveLUT(_ points: [CurvePoint]) -> [Float] {
        return (0..<256).map { index in
            let x = Float(index) / 255
            return CurvePoint.interpolatedValue(at: x, in: points)
        }
    }

    nonisolated static func previewImage(_ image: CIImage, drawableSize: CGSize) -> CIImage {
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

extension ImageEditRenderer {
    /// Renders a saved edit at the source image's native pixel size for export.
    nonisolated static func editedExport(sourceURL: URL, state: ImageEditingState) -> UIImage? {
        let maximumPixelSize: Int
        if let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        {
            let width = (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue ?? 0
            let height = (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue ?? 0
            maximumPixelSize = max(width, height, 16_384)
        } else {
            maximumPixelSize = 16_384
        }

        return editedPreview(
            sourceURL: sourceURL,
            state: state,
            maximumPixelSize: maximumPixelSize
        )
    }

    nonisolated static func editedPreview(sourceURL: URL, state: ImageEditingState, maximumPixelSize: Int = 2048) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(
                  source,
                  0,
                  [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
                  ] as CFDictionary
              )
        else { return nil }

        var image = UIImage(cgImage: cgImage)
        for operation in state.transformOperations {
            switch operation {
            case .rotateRight: image = rotateRight(image)
            case .mirrorHorizontally: image = mirrorHorizontally(image)
            case .mirrorVertically: image = mirrorVertically(image)
            }
        }
        image = crop(image, to: state.normalizedCrop.cgRect)

        guard let input = ImageEditPipeline.sourceImage(
            uiImage: image,
            sourceURL: nil,
            maximumPixelSize: CGFloat(maximumPixelSize)
        ) else { return image }
        let rawDefaults: RawAdjustmentDefaults?
        if sourceURL.isRawImage, let raw = CIRAWFilter(imageURL: sourceURL) {
            rawDefaults = RawAdjustmentDefaults(
                temperature: raw.neutralTemperature > 0 ? raw.neutralTemperature : 6500,
                tint: raw.neutralTint
            )
        } else {
            rawDefaults = nil
        }
        let adjusted = ImageEditPipeline.adjustedImage(input, recipe: state.recipe, rawDefaults: rawDefaults)
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let output = context.createCGImage(adjusted, from: adjusted.extent) else { return image }
        return UIImage(cgImage: output)
    }
}

/// The complete edit state. Values exposed to the controls use the familiar
/// -100...100 range; the renderer maps them to Core Image's native ranges.
struct EditRecipe: Codable, Equatable, Sendable {
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
    var curveRGB: [CurvePoint] = CurvePoint.identity
    var curveRed: [CurvePoint] = CurvePoint.identity
    var curveGreen: [CurvePoint] = CurvePoint.identity
    var curveBlue: [CurvePoint] = CurvePoint.identity

    nonisolated var hasCurveAdjustments: Bool {
        curveRGB != CurvePoint.identity
            || curveRed != CurvePoint.identity
            || curveGreen != CurvePoint.identity
            || curveBlue != CurvePoint.identity
    }

    nonisolated func curve(for channel: CurveChannel) -> [CurvePoint] {
        switch channel {
        case .rgb: return curveRGB
        case .red: return curveRed
        case .green: return curveGreen
        case .blue: return curveBlue
        }
    }

    var withoutCurves: EditRecipe {
        var copy = self
        copy.curveRGB = CurvePoint.identity
        copy.curveRed = CurvePoint.identity
        copy.curveGreen = CurvePoint.identity
        copy.curveBlue = CurvePoint.identity
        return copy
    }
}

private enum AdjustmentSection: String, CaseIterable, Identifiable {
    case brightness, advancedBrightness, color, curves

    var id: String { rawValue }
    var title: String {
        switch self {
        case .brightness: return "亮度"
        case .advancedBrightness: return "高级亮度"
        case .color: return "颜色"
        case .curves: return "曲线"
        }
    }

    var systemImage: String {
        switch self {
        case .brightness: return "lightbulb.max"
        case .advancedBrightness: return "sun.max"
        case .color: return "thermometer.sun"
        case .curves: return "chart.xyaxis.line"
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
    @State private var selectedCurveChannel: CurveChannel = .rgb
    @State private var rawAdjustmentDefaults: RawAdjustmentDefaults?
    @State private var selectedAdjustmentSection: AdjustmentSection = .brightness
    @State private var usesRawSource = false
    @State private var transformOperations: [ImageTransformOperation] = []
    @State private var saveError: String?
    @State private var isExporting = false

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
                let savedRecord = EditedImageStore.shared.record(for: asset.url)
                editRecipe = savedRecord?.state.recipe ?? EditRecipe()
                normalizedCrop = savedRecord?.state.normalizedCrop.cgRect ?? CGRect(x: 0, y: 0, width: 1, height: 1)
                transformOperations = savedRecord?.state.transformOperations ?? []
                if let rawAdjustmentDefaults {
                    if savedRecord == nil {
                        editRecipe.temperature = rawAdjustmentDefaults.temperature
                        editRecipe.tint = rawAdjustmentDefaults.tint
                    }
                }
                if savedRecord != nil {
                    for operation in transformOperations {
                        switch operation {
                        case .rotateRight: image = ImageEditRenderer.rotateRight(image ?? loaded)
                        case .mirrorHorizontally: image = ImageEditRenderer.mirrorHorizontally(image ?? loaded)
                        case .mirrorVertically: image = ImageEditRenderer.mirrorVertically(image ?? loaded)
                        }
                    }
                    usesRawSource = asset.url.isRawImage && transformOperations.isEmpty
                    if let image {
                        isPortraitRatio = image.size.height > image.size.width
                    }
                }
            }
        }
        .alert("无法保存编辑", isPresented: saveErrorPresented) {
            Button("好", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "编辑数据保存失败。")
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
                    imageOpacity: previewOpacity,
                    recipe: editRecipe,
                    rawDefaults: rawAdjustmentDefaults,
                    sourceURL: usesRawSource ? asset.url : nil
                )
                .transition(.opacity)
            } else if selectedTool == .adjustments {
                let previewImage = croppedPreview ?? image
                let previewSourceURL = usesRawSource && croppedPreview == nil ? asset.url : nil
                ZStack(alignment: .topLeading) {
                    AdjustmentPreview(
                        image: previewImage,
                        sourceURL: previewSourceURL,
                        recipe: editRecipe,
                        rawDefaults: rawAdjustmentDefaults
                    )

                    HistogramOverlay(
                        image: previewImage,
                        sourceURL: previewSourceURL,
                        recipe: editRecipe,
                        rawDefaults: rawAdjustmentDefaults,
                        revision: cropRevision
                    )
                    .padding(.leading, 27)
                    .padding(.top, 16)
                }
                .transition(.opacity)
            } else {
                Image(uiImage: croppedPreview ?? ImageEditRenderer.crop(image, to: normalizedCrop))
                    .resizable()
                    .scaledToFit()
                    .allowedDynamicRange(.high)
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
                    .disabled(isExporting)

                Spacer()

                Menu {
                    Button { saveEdits() } label: {
                        Label("保存", systemImage: "checkmark")
                    }
                    Button { saveEditsAndExport() } label: {
                        Label("保存并导出", systemImage: "square.and.arrow.up")
                    }
                    .disabled(isExporting)
                } label: {
                    Group {
                        if isExporting {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Text("保存")
                                .font(.subheadline.bold())
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 4)
                    .glassEffect(.regular.interactive().tint(.blue), in: .capsule)
                }
                .disabled(isExporting)
                .accessibilityLabel("保存编辑")
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
                case .curves:
                    if let image {
                        CurveAdjustmentPanel(
                            recipe: $editRecipe,
                            selectedChannel: $selectedCurveChannel,
                            image: croppedPreview ?? image,
                            sourceURL: usesRawSource && croppedPreview == nil ? asset.url : nil,
                            rawDefaults: rawAdjustmentDefaults,
                            revision: cropRevision
                        )
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 2)
        .frame(maxHeight: selectedAdjustmentSection == .curves ? 474 : 258)
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
            transformOperations.append(.rotateRight)
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
            transformOperations.append(.mirrorHorizontally)
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
            transformOperations.append(.mirrorVertically)
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
            transformOperations = []
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
                      kCGImageSourceThumbnailMaxPixelSize: 4096
                  ] as CFDictionary
              )
        else { return nil }

        return UIImage(cgImage: cgImage)
    }

    private var saveErrorPresented: Binding<Bool> {
        Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )
    }

    private func saveEdits() {
        _ = persistEdits()
        dismiss()
    }

    private func saveEditsAndExport() {
        guard !isExporting else { return }
        let state = persistEdits()
        isExporting = true

        Task { @MainActor in
            do {
                let jpegData = await Task.detached(priority: .userInitiated) { () -> Data? in
                    guard let image = ImageEditRenderer.editedExport(
                        sourceURL: asset.url,
                        state: state
                    ) else {
                        return nil
                    }
                    return image.jpegData(compressionQuality: 0.95)
                }.value

                try Task.checkCancellation()
                guard let jpegData else {
                    throw ImageEditorExportError.renderFailed
                }
                try await saveJPEGToPhotos(jpegData)
                isExporting = false
                dismiss()
            } catch is CancellationError {
                isExporting = false
            } catch {
                isExporting = false
                saveError = error.localizedDescription
            }
        }
    }

    private func persistEdits() -> ImageEditingState {
        let state = ImageEditingState(
            recipe: editRecipe,
            normalizedCrop: NormalizedImageRect(normalizedCrop),
            transformOperations: transformOperations
        )
        _ = EditedImageStore.shared.save(
            sourceURL: asset.url,
            filename: asset.filename,
            state: state,
            thumbnailHandle: asset.thumbnailHandle,
            thumbnailData: asset.thumbnailData
        )
        return state
    }

    private func saveJPEGToPhotos(_ data: Data) async throws {
        let authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard authorization == .authorized || authorization == .limited else {
            throw ImageEditorExportError.photoLibraryAccessDenied
        }

        let filename = URL(fileURLWithPath: asset.filename)
            .deletingPathExtension()
            .lastPathComponent
        let outputName = (filename.isEmpty ? "调整后照片" : filename) + ".jpg"
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "-" + outputName)
        try data.write(to: outputURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: outputURL) }

        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, fileURL: outputURL, options: nil)
        }
    }

    private func rawDefaults(for url: URL) -> RawAdjustmentDefaults? {
        guard url.isRawImage, let raw = CIRAWFilter(imageURL: url) else { return nil }
        return RawAdjustmentDefaults(
            temperature: raw.neutralTemperature > 0 ? raw.neutralTemperature : 6500,
            tint: raw.neutralTint
        )
    }
}
