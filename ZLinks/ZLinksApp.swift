//
//  ZLinksApp.swift
//  ZLinks
//
//  Created by co on 2026/9/10.
//

import SwiftUI

@main
struct ZLinksApp: App {
    @StateObject private var camera = CameraConnectionService()

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(camera)
        }
    }
}
