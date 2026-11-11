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

    /// 426 for an envelope whose `v` is not `ClipEnvelope.currentVersion`.
    public static let upgradeRequired = FileTransferResponse.json(
        426,
        ["status": "upgradeRequired", "minVersion": ClipEnvelope.currentVersion]
    )

    /// 400: `sentAt` is outside the freshness window (clocks out of sync, or an old capture).
    public static let stale = FileTransferResponse.json(400, ["status": "stale"])
    /// 409: this `(sourceDeviceId, nonce)` was already accepted.
    public static let replayed = FileTransferResponse.json(409, ["status": "replayed"])

    /// The rejection for a failed `ReplayGuard` check, or nil when the envelope may proceed.
    public static func rejection(for check: ReplayCheck) -> FileTransferResponse? {
        switch check {
        case .ok: return nil
        case .stale: return .stale
        case .replayed: return .replayed
        }
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
        /// Plaintext bytes of the distinct chunks already on disk.
        var bytesWritten: Int64 = 0
        var lastActivity: Date
    }

    private let pairedStore: PairedDeviceStore
    /// This device's id: the recipient every inbound envelope must be sealed for.
    private let localDeviceId: UUID
    private let transfersDirectory: URL
    private let destinationProvider: @Sendable () -> URL
    private let now: @Sendable () -> Date
    private let idleTimeout: TimeInterval
    private let onEvent: (@Sendable (FileTransferReceiveEvent) -> Void)?
    /// Shared with the clip endpoint in production (one guard per process).
    private let replayGuard: ReplayGuard
    /// Bytes available on the transfers volume.
    private let freeSpaceProvider: @Sendable () -> Int64
    /// Writes one chunk's plaintext at a byte offset (a seam for tests).
    private let chunkWriter: @Sendable (FileHandle, UInt64, Data) throws -> Void

    private var sessions: [String: Session] = [:]
    /// Cancelled transfer id -> when it was cancelled; pruned after `cancelledRetention`.
    private var cancelledTransferIds: [String: Date] = [:]

    public init(
        pairedStore: PairedDeviceStore,
        localDeviceId: UUID,
        transfersDirectory: URL,
        destinationProvider: @escaping @Sendable () -> URL,
        now: @escaping @Sendable () -> Date = { Date() },
        idleTimeout: TimeInterval = FileTransferConstants.idleTimeout,
        replayGuard: ReplayGuard = ReplayGuard(),
        freeSpaceProvider: (@Sendable () -> Int64)? = nil,
        chunkWriter: @escaping @Sendable (FileHandle, UInt64, Data) throws -> Void = FileReceiver.defaultChunkWriter,
        onEvent: (@Sendable (FileTransferReceiveEvent) -> Void)? = nil
    ) {
        self.replayGuard = replayGuard
        self.freeSpaceProvider = freeSpaceProvider ?? { FileReceiver.volumeFreeSpace(at: transfersDirectory) }
        self.chunkWriter = chunkWriter
        self.pairedStore = pairedStore
        self.localDeviceId = localDeviceId
        self.transfersDirectory = transfersDirectory
        self.destinationProvider = destinationProvider
        self.now = now
        self.idleTimeout = idleTimeout
        self.onEvent = onEvent
    }

    public static let defaultChunkWriter: @Sendable (FileHandle, UInt64, Data) throws -> Void = { handle, offset, data in
        try handle.seek(toOffset: offset)
        try handle.write(contentsOf: data)
    }

    /// Free bytes on the volume holding `directory` (its nearest existing ancestor).
    /// Unknown free space does not block transfers.
    static func volumeFreeSpace(at directory: URL) -> Int64 {
        var url = directory
        while !FileManager.default.fileExists(atPath: url.path), url.pathComponents.count > 1 {
            url = url.deletingLastPathComponent()
        }
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage { return important }
        if let available = values?.volumeAvailableCapacity { return Int64(available) }
        return .max
    }

    /// Number of remembered cancelled ids (test hook for pruning).
    var cancelledTransferCount: Int { cancelledTransferIds.count }

    // MARK: - Offer

    public func handleOffer(envelope: ClipEnvelope) async -> FileTransferResponse {
        guard envelope.v == ClipEnvelope.currentVersion else { return .upgradeRequired }
        guard let key = try? await pairedStore.getKey(for: envelope.sourceDeviceId) else {
            return .json(401, ["status": "unpaired"])
        }
        // A pause is local: a remote sender may still attempt delivery and receives 401.
        guard await pairedStore.isConnected(envelope.sourceDeviceId) else {
            return .json(401, ["status": "paused"])
        }
        guard let opened = try? envelope.openStamped(FileOfferPayload.self, purpose: .fileOffer, recipientDeviceId: localDeviceId, pairKey: key) else {
            return .json(401, ["status": "unpaired"])
        }
        if let rejection = await replayRejection(envelope, sentAt: opened.sentAt) { return rejection }
        let offer = opened.payload
        guard isValidTransferId(offer.transferId) else {
            return .json(400, ["status": "invalidId"])
        }
        guard isValidOffer(offer) else {
            return .json(400, ["status": "invalidOffer"])
        }

        if sessions[offer.transferId] != nil {
            return .json(409, ["status": "duplicate"])
        }
        let activeForDevice = sessions.values.filter { $0.sourceDeviceId == envelope.sourceDeviceId }.count
        guard activeForDevice < FileTransferConstants.maxSessionsPerDevice else {
            return .json(429, ["status": "tooManyTransfers"])
        }
        // Space still owed to active sessions counts as used: nothing is preallocated.
        let committed = sessions.values.reduce(Int64(0)) { $0 + ($1.offer.fileSize - $1.bytesWritten) }
        guard offer.fileSize <= freeSpaceProvider() - committed - FileTransferConstants.freeSpaceReserve else {
            return .json(400, ["status": "tooLarge"])
        }

        let tempURL = transfersDirectory.appendingPathComponent("\(offer.transferId).part")
        do {
            try FileManager.default.createDirectory(at: transfersDirectory, withIntermediateDirectories: true)
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
            cancelledTransferIds[offer.transferId] = nil
            emit(.started(transferId: offer.transferId, fileName: offer.fileName, chunkCount: offer.chunkCount))
            return .json(200, ["status": "ready"])
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            return .json(400, ["status": "error"])
        }
    }

    // MARK: - Chunk

    /// Chunks are unauthenticated at the HTTP layer (anyone who sees `X-Transfer-Id` can post
    /// one), so a rejected chunk never touches the session: it stays intact for the real sender.
    public func handleChunk(transferId: String, chunkIndex: Int, body: Data) -> FileTransferResponse {
        if cancelledTransferIds[transferId] != nil {
            return .json(410, ["status": "cancelled"])
        }
        guard var session = sessions[transferId] else {
            return .json(404, ["status": "unknown"])
        }
        guard chunkIndex >= 0, chunkIndex < session.offer.chunkCount else {
            return .json(400, ["status": "badIndex"])
        }

        guard let plaintext = try? FileTransferCrypto.openChunk(body, fileKey: session.fileKey, index: UInt64(chunkIndex)) else {
            return .json(400, ["status": "authFailed"])
        }
        let expectedSize = chunkIndex == session.offer.chunkCount - 1
            ? Int(session.offer.fileSize - Int64(chunkIndex) * Int64(session.offer.chunkSize))
            : session.offer.chunkSize
        guard plaintext.count == expectedSize else {
            return .json(400, ["status": "badSize"])
        }

        // Authenticate duplicate bodies too; idempotence must not bypass AEAD verification.
        if session.receivedIndices.contains(chunkIndex) {
            session.lastActivity = now()
            sessions[transferId] = session
            return .json(200, ["status": "ok", "received": session.receivedIndices.count])
        }

        // The index counts as received only once its bytes are on disk; a retry rewrites it.
        do {
            try chunkWriter(session.handle, UInt64(chunkIndex) * UInt64(session.offer.chunkSize), plaintext)
        } catch {
            return .json(400, ["status": "writeFailed"])
        }

        session.receivedIndices.insert(chunkIndex)
        session.bytesWritten += Int64(plaintext.count)
        session.lastActivity = now()
        sessions[transferId] = session
        emit(.progress(transferId: transferId, received: session.receivedIndices.count, total: session.offer.chunkCount))
        return .json(200, ["status": "ok", "received": session.receivedIndices.count])
    }

    // MARK: - Finish

    public func handleFinish(envelope: ClipEnvelope) async -> FileTransferResponse {
        guard envelope.v == ClipEnvelope.currentVersion else { return .upgradeRequired }
        guard let key = try? await pairedStore.getKey(for: envelope.sourceDeviceId) else {
            return .json(401, ["status": "unpaired"])
        }
        guard await pairedStore.isConnected(envelope.sourceDeviceId) else {
            return .json(401, ["status": "paused"])
        }
        guard let opened = try? envelope.openStamped(FileFinishPayload.self, purpose: .fileFinish, recipientDeviceId: localDeviceId, pairKey: key) else {
            return .json(401, ["status": "unpaired"])
        }
        if let rejection = await replayRejection(envelope, sentAt: opened.sentAt) { return rejection }
        let finish = opened.payload
        // Another paired device must not learn of, or finish, this device's transfer.
        guard let session = sessions[finish.transferId], session.sourceDeviceId == envelope.sourceDeviceId else {
            return .json(404, ["status": "unknown"])
        }

        guard session.receivedIndices.count == session.offer.chunkCount else {
            return .json(409, ["status": "incomplete"])
        }

        try? session.handle.close()

        guard let computedHash = try? ContentHasher.fileHash(contentsOf: session.tempURL) else {
            destroy(finish.transferId, session: session)
            emit(.failed(transferId: finish.transferId, reason: "hash read failed"))
            return .json(422, ["status": "error"])
        }
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
        guard envelope.v == ClipEnvelope.currentVersion else { return .upgradeRequired }
        if let key = try? await pairedStore.getKey(for: envelope.sourceDeviceId) {
            guard await pairedStore.isConnected(envelope.sourceDeviceId) else {
                return .json(401, ["status": "paused"])
            }
            if let opened = try? envelope.openStamped(FileCancelPayload.self, purpose: .fileCancel, recipientDeviceId: localDeviceId, pairKey: key) {
                if let rejection = await replayRejection(envelope, sentAt: opened.sentAt) { return rejection }
                let cancel = opened.payload
                if let session = sessions[cancel.transferId] {
                    guard session.sourceDeviceId == envelope.sourceDeviceId else {
                        return .json(404, ["status": "unknown"])
                    }
                    destroy(cancel.transferId, session: session)
                    emit(.cancelled(transferId: cancel.transferId))
                }
                pruneCancelled()
                cancelledTransferIds[cancel.transferId] = now()
            }
        }
        return .json(200, ["status": "cancelled"])
    }

    // MARK: - Garbage collection

    /// Drops sessions idle longer than `idleTimeout`, deleting their temp files, and forgets
    /// cancelled ids older than `cancelledRetention`.
    public func garbageCollect() {
        let cutoff = now().addingTimeInterval(-idleTimeout)
        for (transferId, session) in sessions where session.lastActivity < cutoff {
            destroy(transferId, session: session)
            emit(.failed(transferId: transferId, reason: "idle timeout"))
        }
        pruneCancelled()
    }

    private func pruneCancelled() {
        let cutoff = now().addingTimeInterval(-FileTransferConstants.cancelledRetention)
        cancelledTransferIds = cancelledTransferIds.filter { $0.value > cutoff }
    }

    // MARK: - Internals

    /// Runs only after a successful AEAD open, before any session change.
    private func replayRejection(_ envelope: ClipEnvelope, sentAt: Date) async -> FileTransferResponse? {
        let check = await replayGuard.check(sourceDeviceId: envelope.sourceDeviceId, nonce: envelope.nonce, sentAt: sentAt)
        return FileTransferResponse.rejection(for: check)
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
        let destination = Self.uniqueDestination(directory: destinationDir, fileName: safeName.isEmpty ? "download" : safeName)
        // Quarantined before the move, so the file is never visible at its destination without it.
        do {
            try Self.applyQuarantine(to: session.tempURL, now: now())
        } catch {
            logToFile("Could not set the quarantine attribute on a received file: \(error)")
        }
        try FileManager.default.moveItem(at: session.tempURL, to: destination)
        return destination
    }

    /// Marks a received file the way browsers mark downloads, so Gatekeeper checks it
    /// before it is opened or run.
    public static func applyQuarantine(to url: URL, now: Date) throws {
        let timestamp = String(UInt64(max(0, now.timeIntervalSince1970)), radix: 16)
        let value = "0081;\(timestamp);ClipboardSS;\(UUID().uuidString)"
        let failureCode: Int32? = value.withCString { bytes in
            setxattr(url.path, "com.apple.quarantine", bytes, strlen(bytes), 0, 0) == 0 ? nil : errno
        }
        if let failureCode {
            throw POSIXError(POSIXErrorCode(rawValue: failureCode) ?? .EIO)
        }
    }

    /// `fileName` in `directory`, or "name (1).ext", "name (2).ext", … if it is taken.
    public static func uniqueDestination(directory: URL, fileName: String) -> URL {
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
