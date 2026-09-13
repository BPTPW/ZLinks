//
//  CaptureControlModels.swift
//  ZLinks
//

import Foundation

enum CaptureParameter: UInt16, CaseIterable, Hashable, Identifiable, Sendable {
    case whiteBalance = 0x5005
    case aperture = 0x5007
    case focusMode = 0x500A
    case meteringMode = 0x500B
    case shutterSpeed = 0x500D
    case exposureMode = 0x500E
    case iso = 0x500F
    case exposureCompensation = 0x5010

    var id: UInt16 { rawValue }

    var title: String {
        switch self {
        case .whiteBalance: return "白平衡"
        case .aperture: return "光圈"
        case .focusMode: return "对焦模式"
        case .meteringMode: return "测光模式"
        case .shutterSpeed: return "快门"
        case .exposureMode: return "曝光模式"
        case .iso: return "ISO"
        case .exposureCompensation: return "曝光补偿"
        }
    }

    var symbol: String {
        switch self {
        case .whiteBalance: return "thermometer.medium"
        case .aperture: return "camera.aperture"
        case .focusMode: return "scope"
        case .meteringMode: return "circle.lefthalf.filled"
        case .shutterSpeed: return "timer"
        case .exposureMode: return "camera.metering.center.weighted"
        case .iso: return "camera.filters"
        case .exposureCompensation: return "plusminus.circle"
        }
    }

    /// Nikon Z bodies expose the same shutter value through 0xD100 when
    /// the standard 0x500D property cannot be written.
    var nikonFallbackCode: UInt16? {
        self == .shutterSpeed ? 0xD100 : nil
    }

    func standardData(for value: UInt64) -> Data {
        switch self {
        case .shutterSpeed:
            if value == 0xFFFF_FFFF || value == 0xFFFF_FFFE || value == 0xFFFF_FFFD {
                return captureUInt32Data(UInt32(truncatingIfNeeded: value))
            }
            let seconds = Self.shutterSeconds(fromPacked: value)
            let scaled = UInt32(max(1, min(Double(UInt32.max), (seconds * 10_000).rounded())))
            return captureUInt32Data(scaled)
        case .iso:
            return captureUInt16Data(UInt16(clamping: value))
        case .exposureCompensation:
            return captureUInt16Data(UInt16(truncatingIfNeeded: value))
        case .whiteBalance, .aperture, .focusMode, .meteringMode, .exposureMode:
            return captureUInt16Data(UInt16(clamping: value))
        }
    }

    func fallbackData(for value: UInt64) -> Data? {
        guard self == .shutterSpeed else { return nil }
        return captureUInt32Data(UInt32(truncatingIfNeeded: value))
    }

    func normalizeStandardRead(_ value: UInt64) -> UInt64 {
        if self == .exposureCompensation {
            return value & 0xFFFF
        }
        guard self == .shutterSpeed else { return value }
        if value == 0xFFFF_FFFF || value == 0xFFFF_FFFE || value == 0xFFFF_FFFD {
            return value
        }
        if ShutterValue.matchesPackedValue(value) {
            return value
        }
        let seconds = Double(value) / 10_000
        return ShutterValue.nearestPackedValue(for: seconds)
    }

    func normalizeFallbackRead(_ value: UInt64) -> UInt64 {
        self == .shutterSpeed ? value : normalizeStandardRead(value)
    }

    private static func shutterSeconds(fromPacked value: UInt64) -> Double {
        let numerator = UInt16((value >> 16) & 0xFFFF)
        let denominator = UInt16(value & 0xFFFF)
        guard numerator > 0, denominator > 0 else { return 1 }
        return Double(numerator) / Double(denominator)
    }
}

struct CaptureOption: Identifiable, Hashable, Sendable {
    let rawValue: UInt64
    let title: String

    var id: UInt64 { rawValue }
}

enum CaptureOptionCatalog {
    static func options(for parameter: CaptureParameter) -> [CaptureOption] {
        switch parameter {
        case .exposureCompensation:
            return exposureCompensationOptions
        case .shutterSpeed:
            return ShutterValue.supported.map { .init(rawValue: $0.packedValue, title: $0.title) }
        case .aperture:
            return apertureOptions
        case .iso:
            return isoOptions
        case .whiteBalance:
            return whiteBalanceOptions
        case .focusMode:
            return focusModeOptions
        case .meteringMode:
            return meteringModeOptions
        case .exposureMode:
            return exposureModeOptions
        }
    }

    static func displayedValue(for parameter: CaptureParameter, rawValue: UInt64?) -> String {
        guard let rawValue else { return "--" }
        switch parameter {
        case .exposureCompensation:
            let signed = Int16(bitPattern: UInt16(truncatingIfNeeded: rawValue))
            let value = Double(signed) / 1_000
            if abs(value) < 0.05 {
                return "±0.0"
            }
            return String(format: "%+.1f", value)
        case .shutterSpeed:
            return ShutterValue.title(forPacked: rawValue)
        case .aperture:
            return String(format: "f/%.1f", Double(rawValue) / 100)
        case .iso:
            return "\(rawValue)"
        case .whiteBalance:
            return title(for: rawValue, in: whiteBalanceOptions)
        case .focusMode:
            return title(for: rawValue, in: focusModeOptions)
        case .meteringMode:
            return title(for: rawValue, in: meteringModeOptions)
        case .exposureMode:
            return title(for: rawValue, in: exposureModeOptions)
        }
    }

    private static func title(for rawValue: UInt64, in options: [CaptureOption]) -> String {
        if let title = options.first(where: { $0.rawValue == rawValue })?.title {
            return title
        }
        let hex = String(rawValue, radix: 16, uppercase: true)
        return "0x" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex
    }

    private static let exposureCompensationOptions: [CaptureOption] = {
        (-15 ... 15).map { step in
            let raw = Int16(clamping: Int64((Double(step) * 1_000 / 3).rounded()))
            let stored = UInt64(UInt16(bitPattern: raw))
            let value = Double(raw) / 1_000
            let title = abs(value) < 0.05 ? "±0.0" : String(format: "%+.1f", value)
            return CaptureOption(rawValue: stored, title: title)
        }
    }()

    private static let apertureOptions: [CaptureOption] = [
        1.4, 1.6, 1.8, 2.0, 2.2, 2.5, 2.8, 3.2, 3.5, 4.0, 4.5, 5.0,
        5.6, 6.3, 7.1, 8.0, 9.0, 10.0, 11.0, 13.0, 14.0, 16.0, 18.0,
        20.0, 22.0, 25.0, 29.0, 32.0
    ].map { aperture in
        CaptureOption(
            rawValue: UInt64((aperture * 100).rounded()),
            title: String(format: "f/%.1f", aperture)
        )
    }

    private static let isoOptions: [CaptureOption] = [
        100, 125, 160, 200, 250, 320, 400, 500, 640, 800, 1_000, 1_250,
        1_600, 2_000, 2_500, 3_200, 4_000, 5_000, 6_400, 8_000, 10_000,
        12_800, 16_000, 20_000, 25_600, 32_000, 40_000, 51_200
    ].map { CaptureOption(rawValue: UInt64($0), title: "\($0)") }

    private static let whiteBalanceOptions: [CaptureOption] = [
        CaptureOption(rawValue: 0x0002, title: "自动"),
        CaptureOption(rawValue: 0x8016, title: "自然光自动"),
        CaptureOption(rawValue: 0x0004, title: "晴天"),
        CaptureOption(rawValue: 0x8010, title: "阴天"),
        CaptureOption(rawValue: 0x8011, title: "阴影"),
        CaptureOption(rawValue: 0x0005, title: "荧光灯"),
        CaptureOption(rawValue: 0x0006, title: "白炽灯"),
        CaptureOption(rawValue: 0x0007, title: "闪光灯"),
        CaptureOption(rawValue: 0x8012, title: "色温"),
        CaptureOption(rawValue: 0x8013, title: "预设")
    ]

    private static let focusModeOptions: [CaptureOption] = [
        CaptureOption(rawValue: 0x8012, title: "AF-A"),
        CaptureOption(rawValue: 0x8010, title: "AF-S"),
        CaptureOption(rawValue: 0x8011, title: "AF-C"),
        CaptureOption(rawValue: 0x8013, title: "AF-F"),
        CaptureOption(rawValue: 0x0001, title: "MF")
    ]

    private static let meteringModeOptions: [CaptureOption] = [
        CaptureOption(rawValue: 0x0003, title: "矩阵"),
        CaptureOption(rawValue: 0x0002, title: "中央重点"),
        CaptureOption(rawValue: 0x0004, title: "中央点"),
        CaptureOption(rawValue: 0x0001, title: "平均")
    ]

    private static let exposureModeOptions: [CaptureOption] = [
        CaptureOption(rawValue: 0x0001, title: "M"),
        CaptureOption(rawValue: 0x0002, title: "P"),
        CaptureOption(rawValue: 0x0003, title: "A"),
        CaptureOption(rawValue: 0x0004, title: "S"),
        CaptureOption(rawValue: 0x8010, title: "AUTO")
    ]
}

private struct ShutterValue {
    let numerator: UInt16
    let denominator: UInt16

    var packedValue: UInt64 {
        UInt64(numerator) << 16 | UInt64(denominator)
    }

    var seconds: Double {
        Double(numerator) / Double(denominator)
    }

    var title: String {
        if denominator == 1 {
            return "\(numerator)s"
        }
        if numerator == 1 {
            return "1/\(denominator)"
        }
        if seconds >= 1 {
            return String(format: "%.1fs", seconds)
        }
        return "1/\(String(format: "%.1f", 1 / seconds))"
    }

    static func title(forPacked value: UInt64) -> String {
        if value == 0xFFFF_FFFF { return "Bulb" }
        if value == 0xFFFF_FFFE { return "x 200" }
        if value == 0xFFFF_FFFD { return "TIME" }
        if let match = supported.first(where: { $0.packedValue == value }) {
            return match.title
        }
        let numerator = UInt16((value >> 16) & 0xFFFF)
        let denominator = UInt16(value & 0xFFFF)
        guard numerator > 0, denominator > 0 else { return "--" }
        if denominator == 1 { return "\(numerator)s" }
        if numerator == 1 { return "1/\(denominator)" }
        return String(format: "%.2fs", Double(numerator) / Double(denominator))
    }

    static func matchesPackedValue(_ value: UInt64) -> Bool {
        let numerator = UInt16((value >> 16) & 0xFFFF)
        let denominator = UInt16(value & 0xFFFF)
        guard numerator > 0, denominator > 0 else { return false }
        if supported.contains(where: { $0.numerator == numerator && $0.denominator == denominator }) {
            return true
        }
        let knownDenominators: Set<UInt16> = [
            1, 2, 3, 4, 5, 6, 8, 10, 13, 15, 20, 25, 30, 40, 50, 60,
            80, 100, 125, 160, 200, 250, 320, 400, 500, 640, 800, 1_000,
            1_250, 1_600, 2_000, 2_500, 3_200, 4_000, 5_000, 6_400, 8_000
        ]
        return numerator <= 30 && knownDenominators.contains(denominator)
    }

    static func nearestPackedValue(for seconds: Double) -> UInt64 {
        supported.min(by: { abs($0.seconds - seconds) < abs($1.seconds - seconds) })?.packedValue
            ?? supported[0].packedValue
    }

    static let supported: [ShutterValue] = [
        .init(numerator: 1, denominator: 8_000),
        .init(numerator: 1, denominator: 6_400),
        .init(numerator: 1, denominator: 5_000),
        .init(numerator: 1, denominator: 4_000),
        .init(numerator: 1, denominator: 3_200),
        .init(numerator: 1, denominator: 2_500),
        .init(numerator: 1, denominator: 2_000),
        .init(numerator: 1, denominator: 1_600),
        .init(numerator: 1, denominator: 1_250),
        .init(numerator: 1, denominator: 1_000),
        .init(numerator: 1, denominator: 800),
        .init(numerator: 1, denominator: 640),
        .init(numerator: 1, denominator: 500),
        .init(numerator: 1, denominator: 400),
        .init(numerator: 1, denominator: 320),
        .init(numerator: 1, denominator: 250),
        .init(numerator: 1, denominator: 200),
        .init(numerator: 1, denominator: 160),
        .init(numerator: 1, denominator: 125),
        .init(numerator: 1, denominator: 100),
        .init(numerator: 1, denominator: 80),
        .init(numerator: 1, denominator: 60),
        .init(numerator: 1, denominator: 50),
        .init(numerator: 1, denominator: 40),
        .init(numerator: 1, denominator: 30),
        .init(numerator: 1, denominator: 25),
        .init(numerator: 1, denominator: 20),
        .init(numerator: 1, denominator: 15),
        .init(numerator: 1, denominator: 13),
        .init(numerator: 1, denominator: 10),
        .init(numerator: 1, denominator: 8),
        .init(numerator: 1, denominator: 6),
        .init(numerator: 1, denominator: 5),
        .init(numerator: 1, denominator: 4),
        .init(numerator: 1, denominator: 3),
        .init(numerator: 2, denominator: 5),
        .init(numerator: 1, denominator: 2),
        .init(numerator: 5, denominator: 8),
        .init(numerator: 10, denominator: 13),
        .init(numerator: 1, denominator: 1),
        .init(numerator: 13, denominator: 10),
        .init(numerator: 8, denominator: 5),
        .init(numerator: 2, denominator: 1),
        .init(numerator: 5, denominator: 2),
        .init(numerator: 3, denominator: 1),
        .init(numerator: 4, denominator: 1),
        .init(numerator: 5, denominator: 1),
        .init(numerator: 6, denominator: 1),
        .init(numerator: 8, denominator: 1),
        .init(numerator: 10, denominator: 1),
        .init(numerator: 13, denominator: 1),
        .init(numerator: 15, denominator: 1),
        .init(numerator: 20, denominator: 1),
        .init(numerator: 25, denominator: 1),
        .init(numerator: 30, denominator: 1)
    ]
}

private func captureUInt16Data(_ value: UInt16) -> Data {
    var littleEndian = value.littleEndian
    return withUnsafeBytes(of: &littleEndian) { Data($0) }
}

private func captureUInt32Data(_ value: UInt32) -> Data {
    var littleEndian = value.littleEndian
    return withUnsafeBytes(of: &littleEndian) { Data($0) }
}
