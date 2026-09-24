//
//  GPSLiveActivityAttributes.swift
//  ZLinks
//

import ActivityKit
import Foundation

struct GPSLiveActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var connectionStatus: String
        var syncStrategy: String
        var lastSyncDate: Date?
        var latitude: Double?
        var longitude: Double?
    }

    var sessionTitle: String
}
