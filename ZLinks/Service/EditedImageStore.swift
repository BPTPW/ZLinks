//
//  EditedImageStore.swift
//  ZLinks
//

import Combine
import Foundation
import UIKit

enum ImageTransformOperation: String, Codable, Sendable {
    case rotateRight
    case mirrorHorizontally
    case mirrorVertically
}

struct NormalizedImageRect: Codable, Equatable, Sendable {
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat

    init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.width
        height = rect.height
    }

    nonisolated var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

struct ImageEditingState: Codable, Equatable, Sendable {
    var recipe: EditRecipe
    var normalizedCrop = NormalizedImageRect(CGRect(x: 0, y: 0, width: 1, height: 1))
    var transformOperations: [ImageTransformOperation] = []
}

struct EditedImageRecord: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let sourcePath: String
    let filename: String
    var state: ImageEditingState
    var editedAt: Date
    var thumbnailHandle: UInt32?
    var thumbnailPath: String?
}

/// Persists non-destructive edits and keeps their source thumbnails alive.
@MainActor
final class EditedImageStore: ObservableObject {
    static let shared = EditedImageStore()

    @Published private(set) var records: [EditedImageRecord] = []

    private let fileManager = FileManager.default
    private lazy var persistenceURL: URL = {
        let directory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("edited-image-records.json")
    }()

    private init() {
        load()
        for record in records {
            registerThumbnailOwner(for: record)
        }
    }

    func record(for sourceURL: URL) -> EditedImageRecord? {
        records.first { $0.sourcePath == sourceURL.path }
    }

    func record(handle: UInt32, filename: String) -> EditedImageRecord? {
        let directory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GalleryEdits", isDirectory: true)
        let safeFilename = URL(fileURLWithPath: filename).lastPathComponent
        return record(for: directory.appendingPathComponent("\(handle)-\(safeFilename)"))
    }

    @discardableResult
    func save(
        sourceURL: URL,
        filename: String,
        state: ImageEditingState,
        thumbnailHandle: UInt32?,
        thumbnailData: Data?
    ) -> EditedImageRecord {
        let existing = record(for: sourceURL)
        let id = existing?.id ?? UUID()
        let ownerID = "edited:\(id.uuidString)"
        var thumbnailPath = existing?.thumbnailPath

        if let thumbnailHandle, let thumbnailData, !thumbnailData.isEmpty {
            let url = ThumbnailCacheService.shared.storeThumbnail(
                thumbnailData,
                handle: thumbnailHandle,
                ownerID: ownerID,
                persistWhenDisabled: true
            )
            thumbnailPath = url?.path ?? thumbnailPath
        } else if let existing {
            registerThumbnailOwner(for: existing)
        }

        let saved = EditedImageRecord(
            id: id,
            sourcePath: sourceURL.path,
            filename: filename,
            state: state,
            editedAt: Date(),
            thumbnailHandle: thumbnailHandle ?? existing?.thumbnailHandle,
            thumbnailPath: thumbnailPath
        )
        if let index = records.firstIndex(where: { $0.id == id }) {
            records.remove(at: index)
            records.insert(saved, at: 0)
        } else {
            records.insert(saved, at: 0)
        }
        persist()
        return saved
    }

    func delete(_ record: EditedImageRecord) {
        let ownerID = "edited:\(record.id.uuidString)"
        if let thumbnailHandle = record.thumbnailHandle {
            ThumbnailCacheService.shared.unregisterOwner(handle: thumbnailHandle, ownerID: ownerID)
        }
        if fileManager.fileExists(atPath: record.sourcePath) {
            try? fileManager.removeItem(atPath: record.sourcePath)
        }
        records.removeAll { $0.id == record.id }
        persist()
    }

    func thumbnail(for record: EditedImageRecord) -> UIImage? {
        guard let path = record.thumbnailPath else { return nil }
        return UIImage(contentsOfFile: path)
    }

    private func registerThumbnailOwner(for record: EditedImageRecord) {
        guard let handle = record.thumbnailHandle else { return }
        let url = record.thumbnailPath.map(URL.init(fileURLWithPath:))
        ThumbnailCacheService.shared.registerOwner(
            handle: handle,
            ownerID: "edited:\(record.id.uuidString)",
            url: url
        )
    }

    private func load() {
        guard let data = try? Data(contentsOf: persistenceURL),
              let decoded = try? JSONDecoder().decode([EditedImageRecord].self, from: data)
        else { return }
        records = decoded.sorted { $0.editedAt > $1.editedAt }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: persistenceURL, options: .atomic)
    }
}
