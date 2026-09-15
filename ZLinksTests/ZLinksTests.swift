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

    private func shutterTitle(numerator: UInt16, denominator: UInt16) -> String {
        shutterTitle(rawValue: UInt64(numerator) << 16 | UInt64(denominator))
    }

    private func shutterTitle(rawValue: UInt64) -> String {
        CaptureOptionCatalog.displayedValue(for: .shutterSpeed, rawValue: rawValue)
    }
}
