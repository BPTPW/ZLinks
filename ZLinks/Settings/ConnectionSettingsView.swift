//
//  ConnectionSettingsView.swift
//  ZLinks
//

import SwiftUI

struct ConnectionSettingsView: View {
    @AppStorage(CameraConnectionService.autoConnectOnLaunchKey) private var autoConnectOnLaunch = false
    @AppStorage(CameraConnectionService.usbFastConnectKey) private var usbFastConnect = true

    var body: some View {
        List {
            Section {
                Toggle("启动时自动连接", isOn: $autoConnectOnLaunch)
                Toggle("USB 快速连接", isOn: $usbFastConnect)
            }
        }
        .navigationTitle("连接")
    }
}
