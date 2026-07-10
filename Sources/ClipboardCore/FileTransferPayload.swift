import Foundation

/// Shared constants for the chunked file-transfer protocol.
/// Canonical spec: docs/wire-protocol.md ("File Transfer Protocol").
public enum FileTransferConstants {
    /// Plaintext chunk size: 4 MiB.
    public static let chunkSize = 4 * 1024 * 1024
    /// HKDF salt for the per-transfer file key.
    public static let fileKeySalt = "ClipboardSS_FileKey"
    /// Receiver session idle timeout before garbage collection.
    public static let idleTimeout: TimeInterval = 60
    /// HTTP header carrying the transfer id on chunk requests (read lowercased).
    public static let transferIdHeader = "X-Transfer-Id"
    /// HTTP header carrying the chunk index on chunk requests (read lowercased).
    public static let chunkIndexHeader = "X-Chunk-Index"
}

/// Inner JSON of `POST /v1/file/offer` (sealed in a `ClipEnvelope`).
///
/// `transferId` is a lowercase UUID string (not a `UUID`) so it serializes identically
/// across Swift/Dart/.NET and matches the value used as HKDF `info` and the
/// `X-Transfer-Id` header byte-for-byte.
public struct FileOfferPayload: Codable, Equatable, Sendable {
    public let transferId: String
    public let fileName: String
    public let fileSize: Int64
    public let mimeType: String
    public let fileHash: String
    public let chunkSize: Int
    public let chunkCount: Int
    public let createdAt: Date
    public let sourceDeviceName: String

    public init(
        transferId: String,
        fileName: String,
        fileSize: Int64,
        mimeType: String,
        fileHash: String,
        chunkSize: Int,
        chunkCount: Int,
        createdAt: Date,
        sourceDeviceName: String
    ) {
        self.transferId = transferId
        self.fileName = fileName
        self.fileSize = fileSize
        self.mimeType = mimeType
        self.fileHash = fileHash
        self.chunkSize = chunkSize
        self.chunkCount = chunkCount
        self.createdAt = createdAt
        self.sourceDeviceName = sourceDeviceName
    }
}

/// Inner JSON of `POST /v1/file/finish`.
public struct FileFinishPayload: Codable, Equatable, Sendable {
    public let transferId: String

    public init(transferId: String) {
        self.transferId = transferId
    }
}

/// Inner JSON of `POST /v1/file/cancel`.
public struct FileCancelPayload: Codable, Equatable, Sendable {
    public let transferId: String

    public init(transferId: String) {
        self.transferId = transferId
    }
}
