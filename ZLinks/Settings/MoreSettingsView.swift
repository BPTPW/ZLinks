//
//  MoreSettingsView.swift
//  ZLinks
//

import SwiftUI

struct MoreSettingsView: View {
    @AppStorage(MapOffsetCorrectionMode.preferenceKey)
    private var mapOffsetCorrectionMode = MapOffsetCorrectionMode.automatic
    @AppStorage(MapLocationMarkerStyle.preferenceKey)
    private var mapLocationMarkerStyle = MapLocationMarkerStyle.accuracyCircle

    var body: some View {
        List {
            Section {
                Picker("地图偏移修正", selection: $mapOffsetCorrectionMode) {
                    ForEach(MapOffsetCorrectionMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .tint(.secondary)

                Picker("标记样式", selection: $mapLocationMarkerStyle) {
                    ForEach(MapLocationMarkerStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.menu)
                .tint(.secondary)
            } header: {
                Text("地图")
            } footer: {
                Text("· 地图偏移修正: 位于中国大陆时，地图坐标系与实际坐标存在偏差，需要进行修正。")
            }
        }
        .navigationTitle("更多")
    }
}
