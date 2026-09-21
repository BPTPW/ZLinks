//
//  ThumbnailCacheService.swift
//  ZLinks
//

import Combine
import Foundation

/// Persistent thumbnail storage shared by the gallery and thumbnail-based lists.
///
/// Files are grouped by the calendar date on which they were written. The
/// ObjectHandle is the stable cache key; owners keep files alive while a list
/// item still needs them (for example, a download task).
@MainActor
final class ThumbnailCacheService: ObservableObject {
    static let shared = ThumbnailCacheService()

    static let cacheEnabledKey = "gallery.thumbnailCache.enabled"
    static let cacheLimitKey = "gallery.thumbnailCache.limitBytes"
    static let cacheExpirationKey = "gallery.thumbnailCache.expirationDays"

    static let defaultLimitBytes: UInt64 = 500 * 1024 * 1024
    static let defaultExpirationDays = 1

    struct CacheLimit: Identifiable, Hashable {
        let bytes: UInt64
        let title: String

        var id: UInt64 { bytes }
    }

    static let cacheLimits: [CacheLimit] = [
        CacheLimit(bytes: 100 * 1024 * 1024, title: "100 MB"),
        CacheLimit(bytes: 500 * 1024 * 1024, title: "500 MB"),
        CacheLimit(bytes: 1 * 1024 * 1024 * 1024, title: "1 GB"),
        CacheLimit(bytes: 2 * 1024 * 1024 * 1024, title: "2 GB")
    ]

    static let expirationOptions: [Int] = [1, 7, 15, 30]

    @Published private(set) var cachedSize: UInt64 = 0

    private struct Entry: Codable {
        var path: String
        var createdAt: Date
        var owners: Set<String>
    }

    private var entries: [UInt32: Entry] = [:]
    private let fileManager = FileManager.default
    private let calendar = Calendar.current
    private lazy var rootURL: URL = {
        let directory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ThumbnailCache", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    private lazy var indexURL: URL = rootURL.appendingPathComponent("index.json")
    private lazy var dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private init() {
        loadIndex()
        refreshStats()
    }

    var isEnabled: Bool {
        if UserDefaults.standard.object(forKey: Self.cacheEnabledKey) == nil { return false }
        return UserDefaults.standard.bool(forKey: Self.cacheEnabledKey)
    }

    var limitBytes: UInt64 {
        let value = UserDefaults.standard.object(forKey: Self.cacheLimitKey) as? NSNumber
        return value.map { UInt64(max(1, $0.int64Value)) } ?? Self.defaultLimitBytes
    }

    var expirationDays: Int {
        let value = UserDefaults.standard.object(forKey: Self.cacheExpirationKey) as? NSNumber
        return value.map { max(1, $0.intValue) } ?? Self.defaultExpirationDays
    }

    var cachedSizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(min(cachedSize, UInt64(Int64.max))), countStyle: .file)
    }

    func loadThumbnail(handle: UInt32) -> Data? {
        guard isEnabled, let entry = entries[handle] else { return nil }
        let url = rootURL.appendingPathComponent(entry.path)
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            entries[handle] = nil
            persistIndex()
            refreshStats()
            return nil
        }
        return data
    }

    @discardableResult
    func storeThumbnail(
        _ data: Data,
        handle: UInt32,
        ownerID: String? = nil,
        persistWhenDisabled: Bool = false
    ) -> URL? {
        guard !data.isEmpty, persistWhenDisabled || isEnabled else { return nil }

        if let oldEntry = entries[handle] {
            let oldURL = rootURL.appendingPathComponent(oldEntry.path)
            try? fileManager.removeItem(at: oldURL)
        }

        let dateName = dateFormatter.string(from: Date())
        let dateDirectory = rootURL.appendingPathComponent(dateName, isDirectory: true)
        try? fileManager.createDirectory(at: dateDirectory, withIntermediateDirectories: true)
        let filename = String(format: "%08X.thumb", handle)
        let url = dateDirectory.appendingPathComponent(filename)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return nil
        }

        var owners = entries[handle]?.owners ?? []
        if let ownerID { owners.insert(ownerID) }
        entries[handle] = Entry(
            path: "\(dateName)/\(filename)",
            createdAt: Date(),
            owners: owners
        )
        persistIndex()
        refreshStats()
        return url
    }

    func registerOwner(handle: UInt32, ownerID: String, url: URL? = nil) {
        guard !ownerID.isEmpty else { return }
        if entries[handle] == nil,
           let url,
           isManagedURL(url),
           fileManager.fileExists(atPath: url.path)
        {
            let relativePath = String(url.path.dropFirst(rootURL.path.count + 1))
            entries[handle] = Entry(path: relativePath, createdAt: Date(), owners: [ownerID])
            persistIndex()
            refreshStats()
            return
        }
        guard var entry = entries[handle] else { return }
        entry.owners.insert(ownerID)
        entries[handle] = entry
        persistIndex()
    }

    func unregisterOwner(handle: UInt32, ownerID: String) {
        guard var entry = entries[handle] else { return }
        entry.owners.remove(ownerID)
        entries[handle] = entry
        persistIndex()
    }

    func isManagedURL(_ url: URL) -> Bool {
        url.path.hasPrefix(rootURL.path + "/")
    }

    /// Call before a thumbnail-producing operation. Expiration and size checks
    /// are intentionally explicit so ordinary cache reads stay inexpensive.
    func prepareForThumbnailWork() {
        removeExpiredEntries()
        enforceSizeLimit()
        refreshStats()
    }

    /// Removes only files that no current feature has registered as an owner.
    func clearUnusedCache() {
        let removableHandles = entries.compactMap { handle, entry in
            entry.owners.isEmpty ? handle : nil
        }
        for handle in removableHandles {
            guard let entry = entries[handle] else { continue }
            try? fileManager.removeItem(at: rootURL.appendingPathComponent(entry.path))
            entries[handle] = nil
        }
        removeOrphanedFiles()
        removeEmptyDateDirectories()
        persistIndex()
        refreshStats()
    }

    func refreshStats() {
        var total: UInt64 = 0
        var staleHandles: [UInt32] = []
        for (handle, entry) in entries {
            let url = rootURL.appendingPathComponent(entry.path)
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? NSNumber
            else {
                staleHandles.append(handle)
                continue
            }
            total = total.addingReportingOverflow(UInt64(max(0, size.int64Value))).overflow
                ? UInt64.max
                : total + UInt64(max(0, size.int64Value))
        }
        for handle in staleHandles {
            entries[handle] = nil
        }
        if !staleHandles.isEmpty { persistIndex() }
        cachedSize = total
    }

    private func removeExpiredEntries() {
        let threshold = calendar.date(byAdding: .day, value: -expirationDays, to: calendar.startOfDay(for: Date())) ?? Date()
        let expiredHandles = entries.compactMap { handle, entry in
            entry.createdAt < threshold && entry.owners.isEmpty ? handle : nil
        }
        for handle in expiredHandles {
            guard let entry = entries[handle] else { continue }
            try? fileManager.removeItem(at: rootURL.appendingPathComponent(entry.path))
            entries[handle] = nil
        }
        removeEmptyDateDirectories()
        persistIndex()
    }

    private func enforceSizeLimit() {
        refreshStats()
        guard cachedSize > limitBytes else { return }

        let candidates = entries
            .filter { $0.value.owners.isEmpty }
            .sorted { $0.value.createdAt < $1.value.createdAt }
        for (handle, entry) in candidates where cachedSize > limitBytes {
            let url = rootURL.appendingPathComponent(entry.path)
            let attributes = try? fileManager.attributesOfItem(atPath: url.path)
            let size = (attributes?[.size] as? NSNumber).map { UInt64(max(0, $0.int64Value)) } ?? 0
            try? fileManager.removeItem(at: url)
            entries[handle] = nil
            cachedSize = cachedSize > size ? cachedSize - size : 0
        }
        removeEmptyDateDirectories()
        persistIndex()
    }

    private func removeEmptyDateDirectories() {
        guard let children = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for url in children where url.lastPathComponent != indexURL.lastPathComponent {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { continue }
            if let contents = try? fileManager.contentsOfDirectory(atPath: url.path), contents.isEmpty {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    private func removeOrphanedFiles() {
        let indexedPaths = Set(entries.values.map(\.path))
        guard let dateDirectories = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for directory in dateDirectories {
            guard directory.lastPathComponent != indexURL.lastPathComponent,
                  (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let files = try? fileManager.contentsOfDirectory(
                      at: directory,
                      includingPropertiesForKeys: [.isDirectoryKey],
                      options: [.skipsHiddenFiles]
                  )
            else { continue }
            for file in files where !indexedPaths.contains("\(directory.lastPathComponent)/\(file.lastPathComponent)") {
                try? fileManager.removeItem(at: file)
            }
        }
    }

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([UInt32: Entry].self, from: data)
        else { return }
        entries = decoded
    }

    private func persistIndex() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}
