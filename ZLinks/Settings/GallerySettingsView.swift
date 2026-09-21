//
//  GallerySettingsView.swift
//  ZLinks
//

import SwiftUI

struct GallerySettingsView: View {
    @ObservedObject private var thumbnailCache = ThumbnailCacheService.shared
    @AppStorage(ThumbnailCacheService.cacheEnabledKey) private var useThumbnailCache = false
    @AppStorage(ThumbnailCacheService.cacheLimitKey)
    private var cacheLimitBytes = Int(ThumbnailCacheService.defaultLimitBytes)
    @AppStorage(ThumbnailCacheService.cacheExpirationKey)
    private var cacheExpirationDays = ThumbnailCacheService.defaultExpirationDays

    var body: some View {
        Form {
            Section("缓存") {
                Toggle("使用缩略图缓存", isOn: $useThumbnailCache)

                Picker("缩略图缓存上限", selection: $cacheLimitBytes) {
                    ForEach(ThumbnailCacheService.cacheLimits) { option in
                        Text(option.title).tag(Int(option.bytes))
                    }
                }

                Picker("缩略图缓存时限", selection: $cacheExpirationDays) {
                    ForEach(ThumbnailCacheService.expirationOptions, id: \.self) { days in
                        Text("\(days)天").tag(days)
                    }
                }

                HStack {
                    Text("已缓存大小")
                    Spacer()
                    Text(thumbnailCache.cachedSizeText)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Button("清除所有缓存", role: .destructive) {
                    thumbnailCache.clearUnusedCache()
                }
                .disabled(thumbnailCache.cachedSize == 0)
            }
        }
        .navigationTitle("图库")
        .onAppear {
            thumbnailCache.refreshStats()
        }
    }
}
