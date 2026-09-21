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

            Section("编辑") {
                NavigationLink {
                    EditedImageListView()
                } label: {
                    Text("已编辑的项目")
                }
            }
        }
        .navigationTitle("图库")
        .onAppear {
            thumbnailCache.refreshStats()
        }
    }
}

private struct EditedImageListView: View {
    @ObservedObject private var store = EditedImageStore.shared

    var body: some View {
        Group {
            if store.records.isEmpty {
                ContentUnavailableView("没有已编辑的项目", systemImage: "slider.horizontal.3")
            } else {
                List {
                    ForEach(store.records) { record in
                        EditedImageRow(record: record)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    store.delete(record)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("已编辑的项目")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct EditedImageRow: View {
    let record: EditedImageRecord
    @State private var thumbnail: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: 58, height: 58)
            .background(Color.secondary.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                Text(record.filename)
                    .font(.body)
                    .lineLimit(1)
                Text(record.editedAt.formatted(
                    .dateTime.year().month().day().hour().minute()
                        .locale(Locale(identifier: "zh_Hans_CN"))
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .task {
            thumbnail = EditedImageStore.shared.thumbnail(for: record)
        }
    }
}
