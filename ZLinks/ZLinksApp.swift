//
//  ZLinksApp.swift
//  ZLinks
//
//  Created by co on 2026/9/10.
//

import SwiftUI
import UIKit

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        AppOrientationController.supportedOrientations
    }
}

@MainActor
enum AppOrientationController {
    private(set) static var supportedOrientations: UIInterfaceOrientationMask = .portrait

    static func allow(_ orientations: UIInterfaceOrientationMask) {
        supportedOrientations = orientations

        for case let windowScene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in windowScene.windows {
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
            windowScene.requestGeometryUpdate(
                .iOS(interfaceOrientations: orientations)
            )
        }
    }
}

@main
struct ZLinksApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var camera = CameraConnectionService()

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(camera)
        }
    }
}
