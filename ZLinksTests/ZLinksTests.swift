//
//  ZLinksTests.swift
//  ZLinksTests
//
//  Created by co on 2026/9/10.
//

import Foundation
import Testing
@testable import ZLinks

struct ZLinksTests {
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
