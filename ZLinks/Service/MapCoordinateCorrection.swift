//
//  MapCoordinateCorrection.swift
//  ZLinks
//

import CoreLocation
import Foundation

enum MapOffsetCorrectionMode: String, CaseIterable, Identifiable {
    case automatic
    case mainlandChina
    case outsideMainlandChina

    static let preferenceKey = "mapOffsetCorrectionMode"

    var id: Self { self }

    var title: String {
        switch self {
        case .automatic: "自动"
        case .mainlandChina: "我在中国大陆"
        case .outsideMainlandChina: "我在中国大陆之外"
        }
    }
}

enum MapCoordinateCorrection {
    private static let earthRadius = 6_378_245.0
    private static let eccentricitySquared = 0.00669342162296594323

    static func coordinateForMap(
        _ coordinate: CLLocationCoordinate2D,
        mode: MapOffsetCorrectionMode,
        locale: Locale = .current
    ) -> CLLocationCoordinate2D {
        let needsCorrection = switch mode {
        case .automatic:
            locale.region?.identifier.uppercased() == "CN"
        case .mainlandChina:
            true
        case .outsideMainlandChina:
            false
        }

        guard needsCorrection else { return coordinate }
        return wgs84ToGCJ02(coordinate)
    }

    static func wgs84ToGCJ02(_ coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        guard CLLocationCoordinate2DIsValid(coordinate), !isOutsideChina(coordinate) else {
            return coordinate
        }

        let latitude = coordinate.latitude
        let longitude = coordinate.longitude
        var latitudeOffset = transformLatitude(longitude - 105, latitude - 35)
        var longitudeOffset = transformLongitude(longitude - 105, latitude - 35)
        let radians = latitude / 180 * .pi
        var magic = sin(radians)
        magic = 1 - eccentricitySquared * magic * magic
        let squareRootMagic = sqrt(magic)
        latitudeOffset = latitudeOffset * 180
            / ((earthRadius * (1 - eccentricitySquared)) / (magic * squareRootMagic) * .pi)
        longitudeOffset = longitudeOffset * 180
            / (earthRadius / squareRootMagic * cos(radians) * .pi)

        return CLLocationCoordinate2D(
            latitude: latitude + latitudeOffset,
            longitude: longitude + longitudeOffset
        )
    }

    private static func isOutsideChina(_ coordinate: CLLocationCoordinate2D) -> Bool {
        coordinate.longitude < 72.004
            || coordinate.longitude > 137.8347
            || coordinate.latitude < 0.8293
            || coordinate.latitude > 55.8271
    }

    private static func transformLatitude(_ x: Double, _ y: Double) -> Double {
        var result = -100 + 2 * x + 3 * y + 0.2 * y * y
            + 0.1 * x * y + 0.2 * sqrt(abs(x))
        result += (20 * sin(6 * x * .pi) + 20 * sin(2 * x * .pi)) * 2 / 3
        result += (20 * sin(y * .pi) + 40 * sin(y / 3 * .pi)) * 2 / 3
        result += (160 * sin(y / 12 * .pi) + 320 * sin(y * .pi / 30)) * 2 / 3
        return result
    }

    private static func transformLongitude(_ x: Double, _ y: Double) -> Double {
        var result = 300 + x + 2 * y + 0.1 * x * x
            + 0.1 * x * y + 0.1 * sqrt(abs(x))
        result += (20 * sin(6 * x * .pi) + 20 * sin(2 * x * .pi)) * 2 / 3
        result += (20 * sin(x * .pi) + 40 * sin(x / 3 * .pi)) * 2 / 3
        result += (150 * sin(x / 12 * .pi) + 300 * sin(x / 30 * .pi)) * 2 / 3
        return result
    }
}
