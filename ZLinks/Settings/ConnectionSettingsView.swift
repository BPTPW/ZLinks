//
//  ConnectionSettingsView.swift
//  ZLinks
//

import SwiftUI

struct ConnectionSettingsView: View {
    @ObservedObject var camera: CameraConnectionService
    @AppStorage(CameraConnectionService.autoConnectOnLaunchKey) private var autoConnectOnLaunch = false
    @AppStorage(CameraConnectionService.usbFastConnectKey) private var usbFastConnect = true

    var body: some View {
        List {
            Section {
                Toggle("启动时自动连接", isOn: $autoConnectOnLaunch)
                Toggle("USB 快速连接", isOn: $usbFastConnect)
            }

            Section {
                Picker("同步策略", selection: Binding(
                    get: { camera.bluetoothGPS.syncStrategy },
                    set: { camera.bluetoothGPS.syncStrategy = $0 }
                )) {
                    ForEach(NikonBluetoothGPSService.SyncStrategy.allCases) { strategy in
                        Text(strategy.title).tag(strategy)
                    }
                }
            } header: {
                Text("GPS 同步")
            }
        }
        .navigationTitle("连接")
    }
}
