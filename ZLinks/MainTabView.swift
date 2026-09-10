//
//  MainTabView.swift
//  ZLinks
//
//  Created by co on 2026/9/10.
//

import SwiftUI

struct MainTabView: View {
    var body: some View {
        TabView {
            MyCameraView()
                .tabItem {
                    Label("我的相机", systemImage: "camera.fill")
                }
            GalleryView()
                .tabItem {
                    Label("图库", systemImage: "photo.on.rectangle")
                }

            CaptureView()
                .tabItem {
                    Label("拍摄", systemImage: "camera.aperture")
                }
        }
    }
}

#Preview {
    MainTabView()
}
