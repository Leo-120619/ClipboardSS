import Foundation

/// Returns the lowercased extension when it is 1-5 ASCII letters or digits, otherwise "png".
/// The extension is peer-supplied, so anything else (separators, dots, "..") is discarded.
public func sanitizedImageExtension(_ fileExtension: String) -> String {
    let scalars = fileExtension.unicodeScalars
    guard (1...5).contains(scalars.count),
          scalars.allSatisfy({ $0.isASCII && CharacterSet.alphanumerics.contains($0) })
    else {
        return "png"
    }
    return fileExtension.lowercased()
}

public final class ClipStore {
    public let storageDirectory: URL
    public private(set) var items: [ClipItem]
    /// Where an unreadable `clips.json` was moved at launch, so the UI can tell the user once.
    public let quarantinedFileURL: URL?

    private let now: () -> Date
    private let fileManager: FileManager
    private let metadataURL: URL
    private let imageDirectory: URL
    private let expirationInterval: TimeInterval
    private let maxUnpinnedClips: Int
    private let maxImageBytes: Int

    public static let defaultMaxUnpinnedClips = 500
    public static let defaultMaxImageBytes = 500 * 1024 * 1024

    public init(
        storageDirectory: URL,
        now: @escaping () -> Date = Date.init,
        fileManager: FileManager = .default,
        expirationInterval: TimeInterval = 7 * 24 * 60 * 60,
        maxUnpinnedClips: Int = ClipStore.defaultMaxUnpinnedClips,
        maxImageBytes: Int = ClipStore.defaultMaxImageBytes
    ) throws {
        self.storageDirectory = storageDirectory
        self.now = now
        self.fileManager = fileManager
        self.expirationInterval = expirationInterval
        self.maxUnpinnedClips = maxUnpinnedClips
        self.maxImageBytes = maxImageBytes
        self.metadataURL = storageDirectory.appendingPathComponent("clips.json")
        self.imageDirectory = storageDirectory.appendingPathComponent("Images", isDirectory: true)

        try fileManager.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: imageDirectory, withIntermediateDirectories: true)

        var items: [ClipItem] = []
        var quarantinedFileURL: URL?
        if fileManager.fileExists(atPath: metadataURL.path) {
            let data = try Data(contentsOf: metadataURL)
            do {
                items = try JSONDecoder.clipStore.decode([ClipItem].self, from: data)
            } catch is DecodingError {
                quarantinedFileURL = try CorruptStateFile.quarantine(metadataURL, now: now(), fileManager: fileManager)
            }
        }
        self.items = items
        self.quarantinedFileURL = quarantinedFileURL
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

        let safeExtension = sanitizedImageExtension(fileExtension)
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

        // File first: if it cannot be removed, memory and clips.json still agree.
        try deleteImageFileIfNeeded(for: items[index])
        items.remove(at: index)
        try save()
    }

    public func cleanupExpiredClips() throws {
        let cutoff = now().addingTimeInterval(-expirationInterval)
        let expired = items.filter { !$0.isPinned && $0.createdAt < cutoff }
        // Runs on every clipboard poll; rewriting unchanged metadata each time adds up to GBs of disk writes.
        guard !expired.isEmpty else { return }

        // Drop only the clips whose files are gone, so a failed delete is retried next time.
        var removed: Set<UUID> = []
        var firstError: Error?
        for clip in expired {
            do {
                try deleteImageFileIfNeeded(for: clip)
                removed.insert(clip.id)
            } catch {
                firstError = firstError ?? error
            }
        }
        if !removed.isEmpty {
            items.removeAll { removed.contains($0.id) }
            try save()
        }
        if let firstError {
            throw firstError
        }
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

        let previousItems = items
        items.insert(clip, at: 0)
        let evicted = evictForHistoryCaps()
        do {
            try save()
        } catch {
            // Nothing is lost: memory goes back to what clips.json still lists.
            items = previousItems
            throw error
        }
        // Only once clips.json no longer lists them; a failure leaves an orphan file, not a broken clip.
        for clip in evicted {
            try? deleteImageFileIfNeeded(for: clip)
        }
        return clip
    }

    /// Removes the oldest unpinned clips (the tail of `items`) from memory until at most
    /// `maxUnpinnedClips` unpinned clips remain and images use at most `maxImageBytes`,
    /// and returns them so their files can be deleted after the save. Pinned clips and
    /// the newest clip are never evicted.
    private func evictForHistoryCaps() -> [ClipItem] {
        var unpinnedCount = items.lazy.filter { !$0.isPinned }.count
        var imageBytes = items.reduce(0) { $0 + imageFileSize(of: $1) }
        var evicted: [ClipItem] = []
        var index = items.count - 1
        while index > 0, unpinnedCount > maxUnpinnedClips || imageBytes > maxImageBytes {
            let clip = items[index]
            let overCount = unpinnedCount > maxUnpinnedClips
            if !clip.isPinned, overCount || clip.imagePath != nil {
                imageBytes -= imageFileSize(of: clip)
                unpinnedCount -= 1
                evicted.append(items.remove(at: index))
            }
            index -= 1
        }
        return evicted
    }

    private func imageFileSize(of clip: ClipItem) -> Int {
        guard let imagePath = clip.imagePath else { return 0 }
        let path = storageDirectory.appendingPathComponent(imagePath).path
        return (try? fileManager.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? 0
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
