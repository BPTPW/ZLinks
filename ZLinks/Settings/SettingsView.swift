//
//  SettingsView.swift
//  ZLinks
//

import SwiftUI

/// Full-screen settings hub presented from the My Camera toolbar.
struct SettingsView: View {
    @ObservedObject var camera: CameraConnectionService

    var body: some View {
        List {
            Section {
                NavigationLink {
                    ConnectionSettingsView()
                } label: {
                    SettingsEntryLabel(
                        title: "连接",
                        symbol: "link",
                        tint: .blue
                    )
                }

                NavigationLink {
                    GallerySettingsView()
                } label: {
                    SettingsEntryLabel(
                        title: "图库",
                        symbol: "photo.on.rectangle",
                        tint: .orange
                    )
                }

                NavigationLink {
                    CaptureSettingsView()
                } label: {
                    SettingsEntryLabel(
                        title: "拍摄",
                        symbol: "camera.aperture",
                        tint: .purple
                    )
                }
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.large)
    }
}

private struct SettingsEntryLabel: View {
    let title: String
    let symbol: String
    let tint: Color

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body)
            }
        } icon: {
            Image(systemName: symbol)
                .font(.subheadline)
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(tint, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}
