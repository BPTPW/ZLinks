//
//  ZLinksTests.swift
//  ZLinksTests
//
//  Created by co on 2026/9/10.
//

import Foundation
import CoreLocation
import Testing
import UIKit
@testable import ZLinks

struct ZLinksTests {
    @Test @MainActor func nikonGeoPayloadHasExpectedWireLayout() {
        let date = Date(timeIntervalSince1970: 1_735_732_800) // 2025-01-01 12:00:00 UTC
        let location = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 34.123456, longitude: -118.654321),
            altitude: 123,
            horizontalAccuracy: 4,
            verticalAccuracy: 3,
            timestamp: date
        )

        let payload = NikonBluetoothGPSService.makeGeoPayload(location: location, date: date)

        #expect(payload.count == 41)
        #expect(Array(payload.prefix(2)) == [0x7F, 0x00])
        #expect(payload[2] == Character("N").asciiValue)
        #expect(payload[7] == Character("W").asciiValue)
        #expect(payload[13] == Character("P").asciiValue)
        #expect(String(data: payload[25..<31], encoding: .ascii) == "WGS-84")
        #expect(payload[24] == 1)
        #expect(payload[31..<41].allSatisfy { $0 == 0 })
    }

    @Test @MainActor func editStateRoundTripsCropTransformsAndAdjustments() throws {
        var recipe = EditRecipe()
        recipe.exposure = 23
        recipe.curveRed = [CurvePoint(x: 0, y: 0.1), CurvePoint(x: 1, y: 0.9)]
        let state = ImageEditingState(
            recipe: recipe,
            normalizedCrop: NormalizedImageRect(CGRect(x: 0.1, y: 0.2, width: 0.7, height: 0.6)),
            transformOperations: [.rotateRight, .mirrorHorizontally]
        )

        let decoded = try JSONDecoder().decode(ImageEditingState.self, from: JSONEncoder().encode(state))
        #expect(decoded == state)
    }

    @Test @MainActor func editedPreviewAppliesRotationAndCrop() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 20), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        try #require(source.pngData()).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let state = ImageEditingState(
            recipe: EditRecipe(),
            normalizedCrop: NormalizedImageRect(CGRect(x: 0, y: 0, width: 0.5, height: 1)),
            transformOperations: [.rotateRight]
        )
        let output = try #require(ImageEditRenderer.editedPreview(sourceURL: url, state: state))
        #expect(output.size == CGSize(width: 10, height: 40))
    }

    @Test func shutterSpeedsBelowOneSecondUseReducedFractions() {
        #expect(shutterTitle(numerator: 1, denominator: 125) == "1/125")
        #expect(shutterTitle(numerator: 2, denominator: 5) == "2/5")
        #expect(shutterTitle(numerator: 12, denominator: 100) == "3/25")
        #expect(shutterTitle(numerator: 16, denominator: 100) == "4/25")
    }

    @Test func shutterSpeedsAtOrAboveOneSecondUseSeconds() {
        #expect(shutterTitle(numerator: 7, denominator: 7) == "1s")
        #expect(shutterTitle(numerator: 3, denominator: 2) == "1.5s")
        #expect(shutterTitle(numerator: 13, denominator: 10) == "1.3s")
    }

    @Test func specialShutterValuesKeepTheirNames() {
        #expect(shutterTitle(rawValue: 0xFFFF_FFFF) == "Bulb")
        #expect(shutterTitle(rawValue: 0xFFFF_FFFE) == "x 200")
        #expect(shutterTitle(rawValue: 0xFFFF_FFFD) == "TIME")
    }

    @Test func metadataPairUsesOnlyJPEGThumbnail() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let records = [UInt32(102), 101].map {
            NikonObjectMetadata(handle: $0, attribute: 0, unknown: 0, captureDate: date)
        }
        let raw = CameraConnectionService.GalleryItem(
            id: 101, filename: "DSC_0001.NEF", objectFormat: 0xb802, fileSize: 100,
            isVideo: false, captureDate: date, rawHandle: 101, rawFilename: "DSC_0001.NEF",
            rawFileSize: 100, jpegHandle: nil, jpegFilename: nil, jpegFileSize: nil
        )
        let jpeg = CameraConnectionService.GalleryItem(
            id: 102, filename: "DSC_0001.JPG", objectFormat: 0x3801, fileSize: 20,
            isVideo: false, captureDate: date, rawHandle: nil, rawFilename: nil,
            rawFileSize: nil, jpegHandle: 102, jpegFilename: "DSC_0001.JPG", jpegFileSize: 20
        )

        let items = CameraConnectionService.buildEnrichedGalleryItems(
            records: records, resolved: [101: raw, 102: jpeg], excludedHandles: []
        )

        #expect(items.count == 1)
        #expect(items.first?.handle == 101)
        #expect(items.first?.thumbnailHandle == 102)
        #expect(!items.contains { $0.handle == 102 })
    }

    private func shutterTitle(numerator: UInt16, denominator: UInt16) -> String {
        shutterTitle(rawValue: UInt64(numerator) << 16 | UInt64(denominator))
    }

    private func shutterTitle(rawValue: UInt64) -> String {
        CaptureOptionCatalog.displayedValue(for: .shutterSpeed, rawValue: rawValue)
    }
}
