//
//  ZLinksTests.swift
//  ZLinksTests
//
//  Created by co on 2026/9/10.
//

import Testing
@testable import ZLinks

struct ZLinksTests {

    @Test func captureParameterLocksFollowExposureMode() {
        #expect(!CaptureParameter.shutterSpeed.isAdjustable(in: CaptureExposureMode.aperturePriority))
        #expect(CaptureParameter.aperture.isAdjustable(in: CaptureExposureMode.aperturePriority))

        #expect(CaptureParameter.shutterSpeed.isAdjustable(in: CaptureExposureMode.shutterPriority))
        #expect(!CaptureParameter.aperture.isAdjustable(in: CaptureExposureMode.shutterPriority))

        #expect(!CaptureParameter.shutterSpeed.isAdjustable(in: CaptureExposureMode.program))
        #expect(!CaptureParameter.aperture.isAdjustable(in: CaptureExposureMode.program))

        #expect(CaptureParameter.shutterSpeed.isAdjustable(in: CaptureExposureMode.manual))
        #expect(CaptureParameter.aperture.isAdjustable(in: CaptureExposureMode.manual))
    }

}
