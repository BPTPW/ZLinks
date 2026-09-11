//
//  CameraWiFiService.swift
//  ZLinks
//

import Combine
import Foundation
import NetworkExtension

@MainActor
final class CameraWiFiService: ObservableObject {
    enum State: Equatable {
        case idle
        case joining
        case joined
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    /// Ask iOS to join a camera access-point network. The system owns the
    /// confirmation UI and the actual Wi-Fi routing decision.
    func joinCameraNetwork(ssid: String, password: String?) async {
        let normalizedSSID = ssid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSSID.isEmpty else {
            state = .failed("请输入相机 Wi-Fi 名称。")
            return
        }

        state = .joining
        let configuration: NEHotspotConfiguration
        if let password, !password.isEmpty {
            configuration = NEHotspotConfiguration(ssid: normalizedSSID, passphrase: password, isWEP: false)
        } else {
            configuration = NEHotspotConfiguration(ssid: normalizedSSID)
        }
        configuration.joinOnce = true

        if await apply(configuration) {
            state = .joined
        } else {
            state = .failed(Self.message())
        }
    }

    func reset() {
        state = .idle
    }

    private func apply(_ configuration: NEHotspotConfiguration) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            NEHotspotConfigurationManager.shared.apply(configuration) { error in
                continuation.resume(returning: error == nil)
            }
        }
    }

    private static func message() -> String {
        return "无法加入相机 Wi-Fi，请确认 SSID 和密码正确。"
    }
}
