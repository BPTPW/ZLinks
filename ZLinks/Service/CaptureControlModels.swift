//
//  CaptureControlModels.swift
//  ZLinks
//

import Foundation

enum CaptureParameter: UInt16, CaseIterable, Hashable, Identifiable, Sendable {
    case whiteBalance = 0x5005
    case aperture = 0x5007
    case focusMode = 0xd061
    case meteringMode = 0x500b
    case shutterSpeed = 0x500d
    case exposureMode = 0x500e
    case iso = 0x500f
    case exposureCompensation = 0x5010

    var id: UInt16 { rawValue }

    var title: String {
        switch self {
        case .whiteBalance: return "白平衡"
        case .aperture: return "光圈"
        case .focusMode: return "对焦模式"
        case .meteringMode: return "测光模式"
        case .shutterSpeed: return "快门"
        case .exposureMode: return "模式"
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

    var usesPresetSelection: Bool {
        switch self {
        case .whiteBalance, .focusMode, .meteringMode, .exposureMode:
            return true
        case .aperture, .shutterSpeed, .iso, .exposureCompensation:
            return false
        }
    }

    static let capabilityCases: [CaptureParameter] = [
        .exposureCompensation,
        .shutterSpeed,
        .aperture,
        .focusMode,
        .iso,
        .whiteBalance,
        .meteringMode
    ]

    /// Alternate property used when the preferred code is not writable.
    /// Nikon Z live-view focus uses 0xD061, while older bodies use 0x500A.
    var fallbackPropertyCode: UInt16? {
        switch self {
        case .shutterSpeed: return 0xd100
        case .focusMode: return 0x500a
        default: return nil
        }
    }

    static func matching(propertyCode: UInt16) -> CaptureParameter? {
        allCases.first {
            $0.rawValue == propertyCode || $0.fallbackPropertyCode == propertyCode
        }
    }

    func standardData(for value: UInt64) -> Data {
        switch self {
        case .shutterSpeed:
            if value == 0xffff_ffff || value == 0xffff_fffe || value == 0xffff_fffd {
                return captureUInt32Data(UInt32(truncatingIfNeeded: value))
            }
            let seconds = Self.shutterSeconds(fromPacked: value)
            let scaled = UInt32(max(1, min(Double(UInt32.max), (seconds * 10_000).rounded())))
            return captureUInt32Data(scaled)
        case .focusMode:
            // Nikon's D061 live-view focus mode uses a single-byte value.
            return captureUInt8Data(UInt8(clamping: value))
        case .iso:
            return captureUInt16Data(UInt16(clamping: value))
        case .exposureCompensation:
            return captureUInt16Data(UInt16(truncatingIfNeeded: value))
        case .whiteBalance, .aperture, .meteringMode, .exposureMode:
            return captureUInt16Data(UInt16(clamping: value))
        }
    }

    func writePropertyCode(for value: UInt64) -> UInt16 {
        return rawValue
    }

    func writeData(for value: UInt64) -> Data {
        return standardData(for: value)
    }

    func fallbackData(for value: UInt64) -> Data? {
        switch self {
        case .shutterSpeed:
            return captureUInt32Data(UInt32(truncatingIfNeeded: value))
        case .focusMode:
            return captureUInt16Data(Self.legacyFocusModeValue(for: value))
        default:
            return nil
        }
    }

    func normalizeStandardRead(_ value: UInt64) -> UInt64 {
        if self == .exposureCompensation {
            return value & 0xffff
        }
        guard self == .shutterSpeed else { return value }
        if value == 0xffff_ffff || value == 0xffff_fffe || value == 0xffff_fffd {
            return value
        }
        if ShutterValue.matchesPackedValue(value) {
            return value
        }
        return Self.packedShutterValue(fromTenThousandths: UInt32(truncatingIfNeeded: value))
    }

    func normalizeFallbackRead(_ value: UInt64) -> UInt64 {
        switch self {
        case .shutterSpeed:
            return value
        case .focusMode:
            return Self.liveViewFocusModeValue(fromLegacy: value)
        default:
            return normalizeStandardRead(value)
        }
    }

    func normalizeRead(_ value: UInt64, from propertyCode: UInt16) -> UInt64 {
        propertyCode == fallbackPropertyCode
            ? normalizeFallbackRead(value)
            : normalizeStandardRead(value)
    }

    private static func legacyFocusModeValue(for liveViewValue: UInt64) -> UInt16 {
        switch liveViewValue {
        case 0: return 0x8010 // AF-S
        case 1: return 0x8011 // AF-C
        case 2: return 0x8013 // AF-F
        case 5: return 0x8012 // AF-A
        case 4: return 0x0001 // MF
        default: return UInt16(clamping: liveViewValue)
        }
    }

    private static func liveViewFocusModeValue(fromLegacy value: UInt64) -> UInt64 {
        switch value & 0xffff {
        case 0x8010: return 0
        case 0x8011: return 1
        case 0x8013: return 2
        case 0x8012: return 5
        case 0x0001: return 4
        case 0x0005: return 5 // AF-A on some standard FocusMode implementations
        default: return value
        }
    }

    private static func shutterSeconds(fromPacked value: UInt64) -> Double {
        let numerator = UInt16((value >> 16) & 0xffff)
        let denominator = UInt16(value & 0xffff)
        guard numerator > 0, denominator > 0 else { return 1 }
        return Double(numerator) / Double(denominator)
    }

    private static func packedShutterValue(fromTenThousandths value: UInt32) -> UInt64 {
        guard value > 0 else { return 0 }
        let divisor = greatestCommonDivisor(value, 10_000)
        let numerator = value / divisor
        let denominator = 10_000 / divisor
        guard numerator <= UInt16.max, denominator <= UInt16.max else {
            return ShutterValue.nearestPackedValue(for: Double(value) / 10_000)
        }
        return UInt64(numerator) << 16 | UInt64(denominator)
    }

    private static func greatestCommonDivisor(_ lhs: UInt32, _ rhs: UInt32) -> UInt32 {
        var first = lhs
        var second = rhs
        while second != 0 {
            (first, second) = (second, first % second)
        }
        return first
    }
}

enum CaptureExposureMode: UInt64, Sendable {
    case manual = 0x0001
    case program = 0x0002
    case aperturePriority = 0x0003
    case shutterPriority = 0x0004
}

extension CaptureParameter {
    func isAdjustable(in exposureMode: CaptureExposureMode?) -> Bool {
        guard self == .shutterSpeed || self == .aperture else { return true }
        guard let exposureMode else { return true }

        switch exposureMode {
        case .manual:
            return true
        case .program:
            return false
        case .aperturePriority:
            return self != .shutterSpeed
        case .shutterPriority:
            return self != .aperture
        }
    }
}

struct CaptureOption: Identifiable, Hashable, Sendable {
    let rawValue: UInt64
    let title: String

    var id: UInt64 { rawValue }
}

enum CapturePropertyDataType: UInt16, Equatable, Sendable {
    case int8 = 0x0001
    case uint8 = 0x0002
    case int16 = 0x0003
    case uint16 = 0x0004
    case int32 = 0x0005
    case uint32 = 0x0006
    case int64 = 0x0007
    case uint64 = 0x0008

    var byteWidth: Int {
        switch self {
        case .int8, .uint8: return 1
        case .int16, .uint16: return 2
        case .int32, .uint32: return 4
        case .int64, .uint64: return 8
        }
    }

    var isSigned: Bool {
        switch self {
        case .int8, .int16, .int32, .int64: return true
        case .uint8, .uint16, .uint32, .uint64: return false
        }
    }

    func signedValue(from rawValue: UInt64) -> Int64 {
        switch self {
        case .int8: return Int64(Int8(bitPattern: UInt8(truncatingIfNeeded: rawValue)))
        case .int16: return Int64(Int16(bitPattern: UInt16(truncatingIfNeeded: rawValue)))
        case .int32: return Int64(Int32(bitPattern: UInt32(truncatingIfNeeded: rawValue)))
        case .int64: return Int64(bitPattern: rawValue)
        case .uint8, .uint16, .uint32, .uint64: return Int64(clamping: rawValue)
        }
    }

    func rawValue(from signedValue: Int64) -> UInt64 {
        switch self {
        case .int8: return UInt64(UInt8(bitPattern: Int8(truncatingIfNeeded: signedValue)))
        case .int16: return UInt64(UInt16(bitPattern: Int16(truncatingIfNeeded: signedValue)))
        case .int32: return UInt64(UInt32(bitPattern: Int32(truncatingIfNeeded: signedValue)))
        case .int64: return UInt64(bitPattern: signedValue)
        case .uint8, .uint16, .uint32, .uint64: return UInt64(clamping: signedValue)
        }
    }
}

enum CapturePropertyForm: Equatable, Sendable {
    case none
    case range(minimum: UInt64, maximum: UInt64, step: UInt64)
    case enumeration([UInt64])
}

struct CapturePropertyDescription: Equatable, Sendable {
    let propertyCode: UInt16
    let dataType: CapturePropertyDataType
    let isWritable: Bool
    let factoryDefaultValue: UInt64
    let currentValue: UInt64
    let form: CapturePropertyForm

    var allowedValues: [UInt64] {
        switch form {
        case .none:
            return []
        case .enumeration(let values):
            return values
        case .range(let minimum, let maximum, let step):
            return rangeValues(minimum: minimum, maximum: maximum, step: step)
        }
    }

    private func rangeValues(minimum: UInt64, maximum: UInt64, step: UInt64) -> [UInt64] {
        let maximumValueCount = 100_000

        if dataType.isSigned {
            let lowerBound = dataType.signedValue(from: minimum)
            let upperBound = dataType.signedValue(from: maximum)
            let stride = dataType.signedValue(from: step)
            guard stride > 0, lowerBound <= upperBound else { return [] }

            var result: [UInt64] = []
            var value = lowerBound
            while value <= upperBound, result.count < maximumValueCount {
                result.append(dataType.rawValue(from: value))
                let (nextValue, overflow) = value.addingReportingOverflow(stride)
                guard !overflow, nextValue <= upperBound else { break }
                value = nextValue
            }
            return result
        }

        guard step > 0, minimum <= maximum else { return [] }
        var result: [UInt64] = []
        var value = minimum
        while value <= maximum, result.count < maximumValueCount {
            result.append(value)
            let (nextValue, overflow) = value.addingReportingOverflow(step)
            guard !overflow, nextValue <= maximum else { break }
            value = nextValue
        }
        return result
    }
}

enum CapturePropertyDescriptionParser {
    static func parse(_ data: Data, expectedPropertyCode: UInt16) -> CapturePropertyDescription? {
        guard data.count >= 7,
              readUInt16(data, at: 0) == expectedPropertyCode,
              let dataType = CapturePropertyDataType(rawValue: readUInt16(data, at: 2))
        else { return nil }

        let width = dataType.byteWidth
        let defaultOffset = 5
        let currentOffset = defaultOffset + width
        let formFlagOffset = currentOffset + width
        guard data.count > formFlagOffset else { return nil }

        let form: CapturePropertyForm
        switch data[formFlagOffset] {
        case 0x00:
            form = .none
        case 0x01:
            let valuesOffset = formFlagOffset + 1
            guard data.count >= valuesOffset + width * 3 else { return nil }
            form = .range(
                minimum: readInteger(data, at: valuesOffset, width: width),
                maximum: readInteger(data, at: valuesOffset + width, width: width),
                step: readInteger(data, at: valuesOffset + width * 2, width: width)
            )
        case 0x02:
            let countOffset = formFlagOffset + 1
            guard data.count >= countOffset + 2 else { return nil }
            let count = Int(readUInt16(data, at: countOffset))
            let valuesOffset = countOffset + 2
            guard count <= (data.count - valuesOffset) / width else { return nil }
            let values = (0..<count).map {
                readInteger(data, at: valuesOffset + $0 * width, width: width)
            }
            form = .enumeration(values)
        default:
            return nil
        }

        return CapturePropertyDescription(
            propertyCode: expectedPropertyCode,
            dataType: dataType,
            isWritable: data[4] != 0,
            factoryDefaultValue: readInteger(data, at: defaultOffset, width: width),
            currentValue: readInteger(data, at: currentOffset, width: width),
            form: form
        )
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func readInteger(_ data: Data, at offset: Int, width: Int) -> UInt64 {
        var result: UInt64 = 0
        for byteIndex in 0..<width {
            result |= UInt64(data[offset + byteIndex]) << UInt64(byteIndex * 8)
        }
        return result
    }
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

    static func options(for parameter: CaptureParameter, rawValues: [UInt64]) -> [CaptureOption] {
        var seen: Set<UInt64> = []
        return rawValues.compactMap { rawValue in
            guard seen.insert(rawValue).inserted else { return nil }
            return CaptureOption(
                rawValue: rawValue,
                title: displayedValue(for: parameter, rawValue: rawValue)
            )
        }
    }

    private static func title(for rawValue: UInt64, in options: [CaptureOption]) -> String {
        if let title = options.first(where: { $0.rawValue == rawValue })?.title {
            return title
        }
        let hex = String(rawValue, radix: 16, uppercase: true)
        return "0x" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex
    }

    private static let exposureCompensationOptions: [CaptureOption] = (-6 ... 6).map { step in
        let raw = Int16(clamping: Int64((Double(step) * 1_000 / 3).rounded()))
        let stored = UInt64(UInt16(bitPattern: raw))
        let value = Double(raw) / 1_000
        let title = abs(value) < 0.05 ? "±0.0" : String(format: "%+.1f", value)
        return CaptureOption(rawValue: stored, title: title)
    }

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
        CaptureOption(rawValue: 0, title: "AF-S"),
        CaptureOption(rawValue: 1, title: "AF-C"),
        CaptureOption(rawValue: 2, title: "AF-F"),
        CaptureOption(rawValue: 5, title: "AF-A"),
        CaptureOption(rawValue: 4, title: "MF")
    ]

    private static let meteringModeOptions: [CaptureOption] = [
        CaptureOption(rawValue: 0x0001, title: "平均"),
        CaptureOption(rawValue: 0x0002, title: "中央重点"),
        CaptureOption(rawValue: 0x0003, title: "矩阵"),
        CaptureOption(rawValue: 0x0004, title: "中央点"),
        CaptureOption(rawValue: 0x8010, title: "亮部重点")
    ]

    private static let exposureModeOptions: [CaptureOption] = [
        CaptureOption(rawValue: 0x0001, title: "M"),
        CaptureOption(rawValue: 0x0002, title: "P"),
        CaptureOption(rawValue: 0x0003, title: "A"),
        CaptureOption(rawValue: 0x0004, title: "S"),
        CaptureOption(rawValue: 0x8010, title: "AUTO"),
        CaptureOption(rawValue: 0x8050, title: "U1"),
        CaptureOption(rawValue: 0x8051, title: "U2"),
        CaptureOption(rawValue: 0x8052, title: "U3")
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
        Self.title(numerator: numerator, denominator: denominator)
    }

    static func title(forPacked value: UInt64) -> String {
        if value == 0xffff_ffff { return "Bulb" }
        if value == 0xffff_fffe { return "x 200" }
        if value == 0xffff_fffd { return "TIME" }
        let numerator = UInt16((value >> 16) & 0xffff)
        let denominator = UInt16(value & 0xffff)
        guard numerator > 0, denominator > 0 else { return "--" }
        return title(numerator: numerator, denominator: denominator)
    }

    private static func title(numerator: UInt16, denominator: UInt16) -> String {
        let seconds = Double(numerator) / Double(denominator)
        if seconds < 1 {
            let divisor = greatestCommonDivisor(numerator, denominator)
            return "\(numerator / divisor)/\(denominator / divisor)"
        }
        return "\(decimalText(seconds))s"
    }

    private static func greatestCommonDivisor(_ lhs: UInt16, _ rhs: UInt16) -> UInt16 {
        var first = lhs
        var second = rhs
        while second != 0 {
            (first, second) = (second, first % second)
        }
        return first
    }

    private static func decimalText(_ value: Double) -> String {
        var text = String(format: "%.2f", value)
        while text.last == "0" {
            text.removeLast()
        }
        if text.last == "." {
            text.removeLast()
        }
        return text
    }

    static func matchesPackedValue(_ value: UInt64) -> Bool {
        let numerator = UInt16((value >> 16) & 0xffff)
        let denominator = UInt16(value & 0xffff)
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

private func captureUInt8Data(_ value: UInt8) -> Data {
    var littleEndian = value.littleEndian
    return withUnsafeBytes(of: &littleEndian) { Data($0) }
}

private func captureUInt16Data(_ value: UInt16) -> Data {
    var littleEndian = value.littleEndian
    return withUnsafeBytes(of: &littleEndian) { Data($0) }
}

private func captureUInt32Data(_ value: UInt32) -> Data {
    var littleEndian = value.littleEndian
    return withUnsafeBytes(of: &littleEndian) { Data($0) }
}
