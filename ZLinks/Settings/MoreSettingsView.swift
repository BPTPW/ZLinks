//
//  MoreSettingsView.swift
//  ZLinks
//

import SwiftUI

struct MoreSettingsView: View {
    @AppStorage(MapOffsetCorrectionMode.preferenceKey)
    private var mapOffsetCorrectionMode = MapOffsetCorrectionMode.automatic

    var body: some View {
        List {
            Section {
                Picker("地图偏移修正", selection: $mapOffsetCorrectionMode) {
                    ForEach(MapOffsetCorrectionMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.menu)
            } footer: {
                Text("用于修正中国大陆 Apple 地图与 GPS、照片位置之间的坐标偏移。自动模式根据设备地区判断。")
            }
        }
        .navigationTitle("更多")
    }
}
