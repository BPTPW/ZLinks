//
//  ImageCropEditorView.swift
//  ZLinks
//

import SwiftUI
import UIKit

struct ImageCropEditorView: View {
    let image: UIImage
    @Binding var normalizedCrop: CGRect
    let aspectRatio: CGFloat?
    let revision: Int
    let previewRotation: Angle
    let previewScaleX: CGFloat
    let previewScaleY: CGFloat
    let imageOpacity: Double
    let recipe: EditRecipe
    let rawDefaults: RawAdjustmentDefaults?
    let sourceURL: URL?

    @State private var imageFrame: CGRect = .zero
    @State private var cropFrame: CGRect = .zero
    @State private var canvasSize: CGSize = .zero
    @State private var dragStartFrame: CGRect = .zero
    @State private var magnifyStartFrame: CGRect = .zero
    @State private var resizeStartFrame: CGRect = .zero
    @State private var activeHandle: CropHandle?
    @State private var isMagnifying = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.clear

                AdjustmentPreview(
                    image: image,
                    sourceURL: sourceURL,
                    recipe: recipe,
                    rawDefaults: rawDefaults
                )
                    .frame(width: imageFrame.width, height: imageFrame.height)
                    .position(x: imageFrame.midX, y: imageFrame.midY)
                    .rotationEffect(previewRotation)
                    .scaleEffect(x: previewScaleX, y: previewScaleY)
                    .opacity(imageOpacity)
                    .gesture(imageDragGesture)
                    .simultaneousGesture(imageMagnificationGesture)

                cropOverlay

                ForEach(CropHandle.allCases) { handle in
                    resizeHandle(handle)
                }
            }
            .clipped()
            .onAppear {
                canvasSize = proxy.size
                layoutFromNormalizedCrop(animated: false)
            }
            .onChange(of: proxy.size) { _, newSize in
                canvasSize = newSize
                layoutFromNormalizedCrop(animated: false)
            }
            .onChange(of: revision) { _, _ in
                layoutFromNormalizedCrop(animated: true)
            }
        }
    }

    private var cropOverlay: some View {
        ZStack {
            CropDimShape(outerRect: imageFrame, cropRect: cropFrame)
                .fill(
                    Color(uiColor: .systemBackground).opacity(0.68),
                    style: FillStyle(eoFill: true)
                )
                .allowsHitTesting(false)

            Path { path in
                guard !cropFrame.isEmpty else { return }
                path.addRect(cropFrame)
                for step in 1 ... 2 {
                    let fraction = CGFloat(step) / 3
                    let x = cropFrame.minX + cropFrame.width * fraction
                    let y = cropFrame.minY + cropFrame.height * fraction
                    path.move(to: CGPoint(x: x, y: cropFrame.minY))
                    path.addLine(to: CGPoint(x: x, y: cropFrame.maxY))
                    path.move(to: CGPoint(x: cropFrame.minX, y: y))
                    path.addLine(to: CGPoint(x: cropFrame.maxX, y: y))
                }
            }
            .stroke(Color.primary.opacity(0.72), lineWidth: 0.8)
            .allowsHitTesting(false)

            CropCornerShape(cropRect: cropFrame)
                .stroke(
                    Color.primary,
                    style: StrokeStyle(lineWidth: 3, lineCap: .square, lineJoin: .miter)
                )
                .allowsHitTesting(false)
        }
    }

    private func resizeHandle(_ handle: CropHandle) -> some View {
        Color.clear
            .frame(width: handle.isCorner ? 48 : 40, height: handle.isCorner ? 48 : 56)
            .contentShape(Rectangle())
            .position(handle.position(in: cropFrame))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if activeHandle != handle {
                            activeHandle = handle
                            resizeStartFrame = cropFrame
                        }
                        cropFrame = resizedCropFrame(
                            from: resizeStartFrame,
                            handle: handle,
                            translation: value.translation
                        )
                    }
                    .onEnded { _ in
                        activeHandle = nil
                        updateNormalizedCrop()
                        layoutFromNormalizedCrop(animated: true)
                    }
            )
    }

    private var imageDragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if value.translation == .zero {
                    dragStartFrame = imageFrame
                } else if dragStartFrame == .zero {
                    dragStartFrame = imageFrame
                }
                var candidate = dragStartFrame.offsetBy(
                    dx: value.translation.width,
                    dy: value.translation.height
                )
                candidate.origin = constrainedImageOrigin(candidate.origin, size: candidate.size)
                imageFrame = candidate
                updateNormalizedCrop()
            }
            .onEnded { _ in
                dragStartFrame = .zero
                updateNormalizedCrop()
            }
    }

    private var imageMagnificationGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if !isMagnifying {
                    isMagnifying = true
                    magnifyStartFrame = imageFrame
                }

                let minimumScale = max(
                    cropFrame.width / magnifyStartFrame.width,
                    cropFrame.height / magnifyStartFrame.height
                )
                let factor = max(value.magnification, minimumScale)
                let anchor = CGPoint(x: cropFrame.midX, y: cropFrame.midY)
                var candidate = CGRect(
                    x: anchor.x - (anchor.x - magnifyStartFrame.minX) * factor,
                    y: anchor.y - (anchor.y - magnifyStartFrame.minY) * factor,
                    width: magnifyStartFrame.width * factor,
                    height: magnifyStartFrame.height * factor
                )
                candidate.origin = constrainedImageOrigin(candidate.origin, size: candidate.size)
                imageFrame = candidate
                updateNormalizedCrop()
            }
            .onEnded { _ in
                isMagnifying = false
                updateNormalizedCrop()
            }
    }

    private func resizedCropFrame(
        from start: CGRect,
        handle: CropHandle,
        translation: CGSize
    ) -> CGRect {
        let bounds = availableBounds.intersection(imageFrame)
        let minimum: CGFloat = 72

        guard let aspectRatio else {
            var minX = start.minX
            var maxX = start.maxX
            var minY = start.minY
            var maxY = start.maxY

            if handle.movesLeft { minX = min(max(start.minX + translation.width, bounds.minX), maxX - minimum) }
            if handle.movesRight { maxX = max(min(start.maxX + translation.width, bounds.maxX), minX + minimum) }
            if handle.movesTop { minY = min(max(start.minY + translation.height, bounds.minY), maxY - minimum) }
            if handle.movesBottom { maxY = max(min(start.maxY + translation.height, bounds.maxY), minY + minimum) }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }

        let anchor = handle.oppositeAnchor(in: start)
        var proposedWidth = start.width
        if handle.movesLeft { proposedWidth = anchor.x - (start.minX + translation.width) }
        if handle.movesRight { proposedWidth = start.maxX + translation.width - anchor.x }
        let proposedHeight = handle.movesTop
            ? anchor.y - (start.minY + translation.height)
            : start.maxY + translation.height - anchor.y
        let widthFromVerticalDrag = proposedHeight * aspectRatio
        if handle.isCorner {
            if abs(widthFromVerticalDrag - start.width) > abs(proposedWidth - start.width) {
                proposedWidth = widthFromVerticalDrag
            }
        } else if !handle.movesLeft && !handle.movesRight {
            proposedWidth = widthFromVerticalDrag
        }

        var width = max(proposedWidth, minimum)
        var height = width / aspectRatio
        if height < minimum {
            height = minimum
            width = height * aspectRatio
        }

        let maximumWidth = handle.maximumWidth(from: anchor, in: bounds)
        let maximumHeight = handle.maximumHeight(from: anchor, in: bounds)
        let factor = min(1, maximumWidth / width, maximumHeight / height)
        width *= factor
        height *= factor

        return handle.rect(width: width, height: height, anchoredAt: anchor)
    }

    private var availableBounds: CGRect {
        CGRect(origin: .zero, size: canvasSize).insetBy(dx: 22, dy: 18)
    }

    private func layoutFromNormalizedCrop(animated: Bool) {
        guard canvasSize.width > 0, canvasSize.height > 0,
              image.size.width > 0, image.size.height > 0
        else { return }

        let crop = normalizedCrop.standardized.clampedToUnit
        let selectedAspect = (image.size.width * crop.width) / (image.size.height * crop.height)
        let target = aspectFit(aspectRatio: selectedAspect, in: availableBounds)
        let scale = target.width / (image.size.width * crop.width)
        let newImageFrame = CGRect(
            x: target.minX - crop.minX * image.size.width * scale,
            y: target.minY - crop.minY * image.size.height * scale,
            width: image.size.width * scale,
            height: image.size.height * scale
        )

        let changes = {
            cropFrame = target
            imageFrame = newImageFrame
        }
        if animated {
            withAnimation(.easeInOut(duration: 0.24), changes)
        } else {
            changes()
        }
    }

    private func updateNormalizedCrop() {
        guard imageFrame.width > 0, imageFrame.height > 0 else { return }
        normalizedCrop = CGRect(
            x: (cropFrame.minX - imageFrame.minX) / imageFrame.width,
            y: (cropFrame.minY - imageFrame.minY) / imageFrame.height,
            width: cropFrame.width / imageFrame.width,
            height: cropFrame.height / imageFrame.height
        ).clampedToUnit
    }

    private func constrainedImageOrigin(_ origin: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(
            x: min(cropFrame.minX, max(cropFrame.maxX - size.width, origin.x)),
            y: min(cropFrame.minY, max(cropFrame.maxY - size.height, origin.y))
        )
    }

    private func aspectFit(aspectRatio: CGFloat, in bounds: CGRect) -> CGRect {
        let width = min(bounds.width, bounds.height * aspectRatio)
        let height = width / aspectRatio
        return CGRect(
            x: bounds.midX - width / 2,
            y: bounds.midY - height / 2,
            width: width,
            height: height
        )
    }
}

private enum CropHandle: CaseIterable, Identifiable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    var id: String { String(describing: self) }
    var isCorner: Bool { self == .topLeft || self == .topRight || self == .bottomRight || self == .bottomLeft }
    var movesLeft: Bool { self == .topLeft || self == .left || self == .bottomLeft }
    var movesRight: Bool { self == .topRight || self == .right || self == .bottomRight }
    var movesTop: Bool { self == .topLeft || self == .top || self == .topRight }
    var movesBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }

    func position(in rect: CGRect) -> CGPoint {
        CGPoint(
            x: movesLeft ? rect.minX : (movesRight ? rect.maxX : rect.midX),
            y: movesTop ? rect.minY : (movesBottom ? rect.maxY : rect.midY)
        )
    }

    func oppositeAnchor(in rect: CGRect) -> CGPoint {
        CGPoint(
            x: movesLeft ? rect.maxX : (movesRight ? rect.minX : rect.midX),
            y: movesTop ? rect.maxY : (movesBottom ? rect.minY : rect.midY)
        )
    }

    func maximumWidth(from anchor: CGPoint, in bounds: CGRect) -> CGFloat {
        if movesLeft { return anchor.x - bounds.minX }
        if movesRight { return bounds.maxX - anchor.x }
        return 2 * min(anchor.x - bounds.minX, bounds.maxX - anchor.x)
    }

    func maximumHeight(from anchor: CGPoint, in bounds: CGRect) -> CGFloat {
        if movesTop { return anchor.y - bounds.minY }
        if movesBottom { return bounds.maxY - anchor.y }
        return 2 * min(anchor.y - bounds.minY, bounds.maxY - anchor.y)
    }

    func rect(width: CGFloat, height: CGFloat, anchoredAt anchor: CGPoint) -> CGRect {
        let x = movesLeft ? anchor.x - width : (movesRight ? anchor.x : anchor.x - width / 2)
        let y = movesTop ? anchor.y - height : (movesBottom ? anchor.y : anchor.y - height / 2)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

private struct CropDimShape: Shape {
    let outerRect: CGRect
    let cropRect: CGRect

    func path(in _: CGRect) -> Path {
        var path = Path()
        path.addRect(outerRect)
        path.addRect(cropRect)
        return path
    }
}

private struct CropCornerShape: Shape {
    let cropRect: CGRect

    func path(in _: CGRect) -> Path {
        let length: CGFloat = 22
        var path = Path()
        let corners = [
            (CGPoint(x: cropRect.minX, y: cropRect.minY), CGFloat(1), CGFloat(1)),
            (CGPoint(x: cropRect.maxX, y: cropRect.minY), CGFloat(-1), CGFloat(1)),
            (CGPoint(x: cropRect.maxX, y: cropRect.maxY), CGFloat(-1), CGFloat(-1)),
            (CGPoint(x: cropRect.minX, y: cropRect.maxY), CGFloat(1), CGFloat(-1))
        ]
        for (corner, horizontal, vertical) in corners {
            path.move(to: CGPoint(x: corner.x + horizontal * length, y: corner.y))
            path.addLine(to: corner)
            path.addLine(to: CGPoint(x: corner.x, y: corner.y + vertical * length))
        }
        return path
    }
}

private extension CGRect {
    var clampedToUnit: CGRect {
        let minX = min(max(self.minX, 0), 1)
        let minY = min(max(self.minY, 0), 1)
        let maxX = min(max(self.maxX, minX), 1)
        let maxY = min(max(self.maxY, minY), 1)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

enum ImageEditRenderer {
    nonisolated static func crop(_ image: UIImage, to normalizedRect: CGRect) -> UIImage {
        let normalized = normalizedImage(image)
        guard let cgImage = normalized.cgImage else { return normalized }
        let rect = CGRect(
            x: normalizedRect.minX * CGFloat(cgImage.width),
            y: normalizedRect.minY * CGFloat(cgImage.height),
            width: normalizedRect.width * CGFloat(cgImage.width),
            height: normalizedRect.height * CGFloat(cgImage.height)
        ).integral.intersection(CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        guard !rect.isEmpty, let cropped = cgImage.cropping(to: rect) else { return normalized }
        return UIImage(cgImage: cropped, scale: normalized.scale, orientation: .up)
    }

    nonisolated static func rotateRight(_ image: UIImage) -> UIImage {
        let source = normalizedImage(image)
        let size = CGSize(width: source.size.height, height: source.size.width)
        return render(size: size, scale: source.scale) { context in
            context.translateBy(x: size.width, y: 0)
            context.rotate(by: .pi / 2)
            source.draw(in: CGRect(origin: .zero, size: source.size))
        }
    }

    nonisolated static func mirrorHorizontally(_ image: UIImage) -> UIImage {
        let source = normalizedImage(image)
        return render(size: source.size, scale: source.scale) { context in
            context.translateBy(x: source.size.width, y: 0)
            context.scaleBy(x: -1, y: 1)
            source.draw(in: CGRect(origin: .zero, size: source.size))
        }
    }

    nonisolated static func mirrorVertically(_ image: UIImage) -> UIImage {
        let source = normalizedImage(image)
        return render(size: source.size, scale: source.scale) { context in
            context.translateBy(x: 0, y: source.size.height)
            context.scaleBy(x: 1, y: -1)
            source.draw(in: CGRect(origin: .zero, size: source.size))
        }
    }

    nonisolated private static func normalizedImage(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        return render(size: image.size, scale: image.scale) { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    nonisolated private static func render(
        size: CGSize,
        scale: CGFloat,
        drawing: (CGContext) -> Void
    ) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { rendererContext in
            drawing(rendererContext.cgContext)
        }
    }
}
