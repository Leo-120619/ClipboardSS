import Foundation

public enum ClipType: String, Codable, Equatable, Sendable {
    case text
    case image
}

public struct ClipItem: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var type: ClipType
    public var createdAt: Date
    public var lastCopiedAt: Date?
    public var isPinned: Bool
    public var text: String?
    public var imagePath: String?
    public var previewText: String
    public var contentHash: String

    public init(
        id: UUID = UUID(),
        type: ClipType,
        createdAt: Date,
        lastCopiedAt: Date? = nil,
        isPinned: Bool = false,
        text: String? = nil,
        imagePath: String? = nil,
        previewText: String,
        contentHash: String
    ) {
        self.id = id
        self.type = type
        self.createdAt = createdAt
        self.lastCopiedAt = lastCopiedAt
        self.isPinned = isPinned
        self.text = text
        self.imagePath = imagePath
        self.previewText = previewText
        self.contentHash = contentHash
    }

    public func resolvedImageURL(baseDirectory: URL) -> URL {
        guard let imagePath else {
            return baseDirectory
        }

        return baseDirectory.appendingPathComponent(imagePath)
    }
}
