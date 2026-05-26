import Foundation

public final class ClipStore {
    public let storageDirectory: URL
    public private(set) var items: [ClipItem]

    private let now: () -> Date
    private let fileManager: FileManager
    private let metadataURL: URL
    private let imageDirectory: URL
    private let expirationInterval: TimeInterval

    public init(
        storageDirectory: URL,
        now: @escaping () -> Date = Date.init,
        fileManager: FileManager = .default,
        expirationInterval: TimeInterval = 7 * 24 * 60 * 60
    ) throws {
        self.storageDirectory = storageDirectory
        self.now = now
        self.fileManager = fileManager
        self.expirationInterval = expirationInterval
        self.metadataURL = storageDirectory.appendingPathComponent("clips.json")
        self.imageDirectory = storageDirectory.appendingPathComponent("Images", isDirectory: true)

        try fileManager.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: imageDirectory, withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: metadataURL.path) {
            let data = try Data(contentsOf: metadataURL)
            self.items = try JSONDecoder.clipStore.decode([ClipItem].self, from: data)
        } else {
            self.items = []
        }
    }

    @discardableResult
    public func addText(_ text: String) throws -> ClipItem {
        let trimmedPreview = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = trimmedPreview.isEmpty ? "Empty text" : trimmedPreview
        let clip = ClipItem(
            type: .text,
            createdAt: now(),
            text: text,
            previewText: preview,
            contentHash: ContentHasher.textHash(text)
        )

        return try upsert(clip)
    }

    @discardableResult
    public func addImageData(
        _ data: Data,
        fileExtension: String,
        previewText: String = "Image"
    ) throws -> ClipItem {
        let hash = ContentHasher.imageHash(data)
        if let existing = items.first(where: { $0.contentHash == hash }) {
            return try refreshExistingClip(existing)
        }

        let normalizedExtension = fileExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeExtension = normalizedExtension.isEmpty ? "png" : normalizedExtension
        let relativePath = "Images/\(UUID().uuidString).\(safeExtension)"
        let imageURL = storageDirectory.appendingPathComponent(relativePath)
        try data.write(to: imageURL, options: .atomic)

        let clip = ClipItem(
            type: .image,
            createdAt: now(),
            imagePath: relativePath,
            previewText: previewText,
            contentHash: hash
        )

        return try upsert(clip)
    }

    public func setPinned(_ id: UUID, _ isPinned: Bool) throws {
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            return
        }

        items[index].isPinned = isPinned
        try save()
    }

    public func markCopied(_ id: UUID) throws {
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            return
        }

        items[index].lastCopiedAt = now()
        let clip = items.remove(at: index)
        items.insert(clip, at: 0)
        try save()
    }

    public func delete(_ id: UUID) throws {
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            return
        }

        let clip = items.remove(at: index)
        try deleteImageFileIfNeeded(for: clip)
        try save()
    }

    public func cleanupExpiredClips() throws {
        let cutoff = now().addingTimeInterval(-expirationInterval)
        let expired = items.filter { !$0.isPinned && $0.createdAt < cutoff }
        items.removeAll { !$0.isPinned && $0.createdAt < cutoff }

        for clip in expired {
            try deleteImageFileIfNeeded(for: clip)
        }

        try save()
    }

    public func clips(matching query: String, filter: ClipFilter = .all) -> [ClipItem] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return items.filter { clip in
            let matchesFilter: Bool = switch filter {
            case .all:
                true
            case .text:
                clip.type == .text
            case .image:
                clip.type == .image
            case .pinned:
                clip.isPinned
            }
            let matchesQuery = normalizedQuery.isEmpty
                || clip.previewText.lowercased().contains(normalizedQuery)
                || (clip.text?.lowercased().contains(normalizedQuery) ?? false)
            return matchesFilter && matchesQuery
        }
    }

    private func upsert(_ clip: ClipItem) throws -> ClipItem {
        if let existing = items.first(where: { $0.contentHash == clip.contentHash }) {
            return try refreshExistingClip(existing)
        }

        items.insert(clip, at: 0)
        try save()
        return clip
    }

    private func refreshExistingClip(_ existing: ClipItem) throws -> ClipItem {
        guard let index = items.firstIndex(where: { $0.id == existing.id }) else {
            return existing
        }

        var refreshed = items.remove(at: index)
        refreshed.createdAt = now()
        items.insert(refreshed, at: 0)
        try save()
        return refreshed
    }

    private func save() throws {
        let data = try JSONEncoder.clipStore.encode(items)
        try data.write(to: metadataURL, options: .atomic)
    }

    private func deleteImageFileIfNeeded(for clip: ClipItem) throws {
        guard let imagePath = clip.imagePath else {
            return
        }

        let url = storageDirectory.appendingPathComponent(imagePath)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }
}

private extension JSONEncoder {
    static var clipStore: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var clipStore: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
