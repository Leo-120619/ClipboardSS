import Foundation

public struct ClipPayload: Codable, Equatable, Sendable {
    public let id: UUID
    public let type: ClipType
    public let createdAt: Date
    public let text: String?
    public let imageBase64: String?
    public let imageExtension: String?
    public let previewText: String
    public let contentHash: String
    public let sourceDeviceName: String

    public init(
        id: UUID,
        type: ClipType,
        createdAt: Date,
        text: String? = nil,
        imageBase64: String? = nil,
        imageExtension: String? = nil,
        previewText: String,
        contentHash: String,
        sourceDeviceName: String
    ) {
        self.id = id
        self.type = type
        self.createdAt = createdAt
        self.text = text
        self.imageBase64 = imageBase64
        self.imageExtension = imageExtension
        self.previewText = previewText
        self.contentHash = contentHash
        self.sourceDeviceName = sourceDeviceName
    }
}
