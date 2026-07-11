import Foundation
import CryptoKit

/// Response returned by the receiver for a `/v1/file/*` request, translated into an
/// `HTTPResponse` by the server layer.
public struct FileTransferResponse: Sendable, Equatable {
    public let statusCode: Int
    public let body: Data

    public init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }

    static func json(_ status: Int, _ object: [String: Any]) -> FileTransferResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        return FileTransferResponse(statusCode: status, body: data)
    }

    static func status(_ status: Int) -> FileTransferResponse {
        FileTransferResponse(statusCode: status, body: Data("{}".utf8))
    }
}

/// UI-facing events emitted as a transfer progresses on the receiving side.
public enum FileTransferReceiveEvent: Sendable, Equatable {
    case started(transferId: String, fileName: String, chunkCount: Int)
    case progress(transferId: String, received: Int, total: Int)
    case completed(transferId: String, url: URL)
    case failed(transferId: String, reason: String)
    case cancelled(transferId: String)
}

/// Receives chunked file transfers. An `actor` because chunk writes touch the filesystem
/// and must never block the main thread. Sessions live in memory; chunk plaintext is
/// written to a `.part` temp file at `index * chunkSize` offsets; sessions GC after an
/// idle timeout.
public actor FileReceiver {
    private struct Session {
        let offer: FileOfferPayload
        let sourceDeviceId: UUID
        let fileKey: SymmetricKey
        let tempURL: URL
        let handle: FileHandle
        var receivedIndices: Set<Int>
        var lastActivity: Date
    }

    private let pairedStore: PairedDeviceStore
    private let transfersDirectory: URL
    private let destinationProvider: @Sendable () -> URL
    private let now: @Sendable () -> Date
    private let idleTimeout: TimeInterval
    private let onEvent: (@Sendable (FileTransferReceiveEvent) -> Void)?

    private var sessions: [String: Session] = [:]
    private var cancelledTransferIds: Set<String> = []

    public init(
        pairedStore: PairedDeviceStore,
        transfersDirectory: URL,
        destinationProvider: @escaping @Sendable () -> URL,
        now: @escaping @Sendable () -> Date = { Date() },
        idleTimeout: TimeInterval = FileTransferConstants.idleTimeout,
        onEvent: (@Sendable (FileTransferReceiveEvent) -> Void)? = nil
    ) {
        self.pairedStore = pairedStore
        self.transfersDirectory = transfersDirectory
        self.destinationProvider = destinationProvider
        self.now = now
        self.idleTimeout = idleTimeout
        self.onEvent = onEvent
    }

    // MARK: - Offer

    public func handleOffer(envelope: ClipEnvelope) async -> FileTransferResponse {
        guard let key = try? await pairedStore.getKey(for: envelope.sourceDeviceId) else {
            return .json(401, ["status": "unpaired"])
        }
        // A pause is local: a remote sender may still attempt delivery and receives 401.
        guard await pairedStore.isConnected(envelope.sourceDeviceId) else {
            return .json(401, ["status": "paused"])
        }
        guard let offer = try? envelope.open(FileOfferPayload.self, pairKey: key) else {
            return .json(401, ["status": "unpaired"])
        }
        guard isValidTransferId(offer.transferId) else {
            return .json(400, ["status": "invalidId"])
        }
        guard isValidOffer(offer) else {
            return .json(400, ["status": "invalidOffer"])
        }

        if sessions[offer.transferId] != nil {
            return .json(409, ["status": "duplicate"])
        }

        do {
            try FileManager.default.createDirectory(at: transfersDirectory, withIntermediateDirectories: true)
            let tempURL = transfersDirectory.appendingPathComponent("\(offer.transferId).part")
            FileManager.default.createFile(atPath: tempURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: tempURL)

            let fileKey = FileTransferCrypto.deriveFileKey(pairKey: key, transferId: offer.transferId)
            sessions[offer.transferId] = Session(
                offer: offer,
                sourceDeviceId: envelope.sourceDeviceId,
                fileKey: fileKey,
                tempURL: tempURL,
                handle: handle,
                receivedIndices: [],
                lastActivity: now()
            )
            cancelledTransferIds.remove(offer.transferId)
            emit(.started(transferId: offer.transferId, fileName: offer.fileName, chunkCount: offer.chunkCount))
            return .json(200, ["status": "ready"])
        } catch {
            return .json(400, ["status": "error"])
        }
    }

    // MARK: - Chunk

    public func handleChunk(transferId: String, chunkIndex: Int, body: Data) -> FileTransferResponse {
        if cancelledTransferIds.contains(transferId) {
            return .json(410, ["status": "cancelled"])
        }
        guard var session = sessions[transferId] else {
            return .json(404, ["status": "unknown"])
        }
        guard chunkIndex >= 0, chunkIndex < session.offer.chunkCount else {
            teardown(transferId, reason: "bad chunk index")
            return .json(400, ["status": "badIndex"])
        }

        guard let plaintext = try? FileTransferCrypto.openChunk(body, fileKey: session.fileKey, index: UInt64(chunkIndex)) else {
            teardown(transferId, reason: "chunk authentication failed")
            return .json(400, ["status": "authFailed"])
        }
        let expectedSize = chunkIndex == session.offer.chunkCount - 1
            ? Int(session.offer.fileSize - Int64(chunkIndex) * Int64(session.offer.chunkSize))
            : session.offer.chunkSize
        guard plaintext.count == expectedSize else {
            teardown(transferId, reason: "bad chunk size")
            return .json(400, ["status": "badSize"])
        }

        // Authenticate duplicate bodies too; idempotence must not bypass AEAD verification.
        if session.receivedIndices.contains(chunkIndex) {
            session.lastActivity = now()
            sessions[transferId] = session
            return .json(200, ["status": "ok", "received": session.receivedIndices.count])
        }

        do {
            try session.handle.seek(toOffset: UInt64(chunkIndex) * UInt64(session.offer.chunkSize))
            try session.handle.write(contentsOf: plaintext)
        } catch {
            teardown(transferId, reason: "write failed")
            return .json(400, ["status": "writeFailed"])
        }

        session.receivedIndices.insert(chunkIndex)
        session.lastActivity = now()
        sessions[transferId] = session
        emit(.progress(transferId: transferId, received: session.receivedIndices.count, total: session.offer.chunkCount))
        return .json(200, ["status": "ok", "received": session.receivedIndices.count])
    }

    // MARK: - Finish

    public func handleFinish(envelope: ClipEnvelope) async -> FileTransferResponse {
        guard let key = try? await pairedStore.getKey(for: envelope.sourceDeviceId),
              let finish = try? envelope.open(FileFinishPayload.self, pairKey: key) else {
            return .json(401, ["status": "unpaired"])
        }
        guard let session = sessions[finish.transferId] else {
            return .json(404, ["status": "unknown"])
        }

        guard session.receivedIndices.count == session.offer.chunkCount else {
            return .json(409, ["status": "incomplete"])
        }

        try? session.handle.close()

        let computedHash = (try? ContentHasher.fileHash(contentsOf: session.tempURL)) ?? ""
        guard computedHash == session.offer.fileHash else {
            destroy(finish.transferId, session: session)
            emit(.failed(transferId: finish.transferId, reason: "hash mismatch"))
            return .json(422, ["status": "hashMismatch"])
        }

        do {
            let destination = try finalize(session: session)
            sessions[finish.transferId] = nil
            emit(.completed(transferId: finish.transferId, url: destination))
            return .json(200, ["status": "complete", "fileName": destination.lastPathComponent])
        } catch {
            destroy(finish.transferId, session: session)
            emit(.failed(transferId: finish.transferId, reason: "finalize failed"))
            return .json(422, ["status": "error"])
        }
    }

    // MARK: - Cancel

    public func handleCancel(envelope: ClipEnvelope) async -> FileTransferResponse {
        if let key = try? await pairedStore.getKey(for: envelope.sourceDeviceId),
           let cancel = try? envelope.open(FileCancelPayload.self, pairKey: key) {
            cancelledTransferIds.insert(cancel.transferId)
            if let session = sessions[cancel.transferId] {
                destroy(cancel.transferId, session: session)
                emit(.cancelled(transferId: cancel.transferId))
            }
        }
        return .json(200, ["status": "cancelled"])
    }

    // MARK: - Garbage collection

    /// Drops sessions idle longer than `idleTimeout`, deleting their temp files.
    public func garbageCollect() {
        let cutoff = now().addingTimeInterval(-idleTimeout)
        for (transferId, session) in sessions where session.lastActivity < cutoff {
            destroy(transferId, session: session)
            emit(.failed(transferId: transferId, reason: "idle timeout"))
        }
    }

    // MARK: - Internals

    private func teardown(_ transferId: String, reason: String) {
        if let session = sessions[transferId] {
            destroy(transferId, session: session)
        }
        emit(.failed(transferId: transferId, reason: reason))
    }

    private func destroy(_ transferId: String, session: Session) {
        try? session.handle.close()
        try? FileManager.default.removeItem(at: session.tempURL)
        sessions[transferId] = nil
    }

    private func finalize(session: Session) throws -> URL {
        let destinationDir = destinationProvider()
        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        let safeName = (session.offer.fileName as NSString).lastPathComponent
        let destination = uniqueDestination(directory: destinationDir, fileName: safeName.isEmpty ? "download" : safeName)
        try FileManager.default.moveItem(at: session.tempURL, to: destination)
        return destination
    }

    private func uniqueDestination(directory: URL, fileName: String) -> URL {
        let candidate = directory.appendingPathComponent(fileName)
        if !FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        let nsName = fileName as NSString
        let base = nsName.deletingPathExtension
        let ext = nsName.pathExtension
        var index = 1
        while true {
            let name = ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)"
            let url = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) {
                return url
            }
            index += 1
        }
    }

    private func emit(_ event: FileTransferReceiveEvent) {
        onEvent?(event)
    }

    private func isValidTransferId(_ transferId: String) -> Bool {
        guard transferId.utf8.count <= 64, !transferId.isEmpty else { return false }
        return transferId.utf8.allSatisfy { byte in
            (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57) || byte == 45
        }
    }

    private func isValidOffer(_ offer: FileOfferPayload) -> Bool {
        guard offer.chunkSize > 0,
              offer.chunkSize <= FileTransferConstants.maxChunkSize,
              offer.fileSize >= 0 else { return false }
        let chunkSize = Int64(offer.chunkSize)
        let expectedCount = offer.fileSize / chunkSize + (offer.fileSize % chunkSize == 0 ? 0 : 1)
        return expectedCount == Int64(offer.chunkCount)
    }
}
