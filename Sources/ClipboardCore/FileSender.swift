import Foundation
import CryptoKit

public enum FileSendError: Error, Equatable {
    case notPaired
    case fileUnreadable
    case cancelled
    case httpStatus(endpoint: String, statusCode: Int)
}

/// Sends a single file to one paired peer using the chunked protocol. Streams the file in
/// 4 MiB slices via `FileHandle` — never loads the whole file. Two passes: a streaming
/// hash pass, then offer → chunks → finish. Reports monotonic progress and honours
/// cancellation, best-effort issuing `/v1/file/cancel` on any failure after the offer.
public struct FileSender: Sendable {
    private let identity: DeviceIdentity
    public let pairedStore: PairedDeviceStore
    private let transport: PeerTransport

    public init(identity: DeviceIdentity, pairedStore: PairedDeviceStore, transport: PeerTransport) {
        self.identity = identity
        self.pairedStore = pairedStore
        self.transport = transport
    }

    /// - Parameters:
    ///   - progress: called with a value in 0...1 after each chunk (monotonic).
    ///   - isCancelled: polled before each chunk; returning true aborts the transfer.
    public func sendFile(
        at url: URL,
        to peer: Peer,
        mimeType: String = "application/octet-stream",
        progress: (@Sendable (Double) -> Void)? = nil,
        isCancelled: (@Sendable () -> Bool)? = nil
    ) async throws {
        guard let key = try? await pairedStore.getKey(for: peer.id) else {
            throw FileSendError.notPaired
        }

        let chunkSize = FileTransferConstants.chunkSize
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = (attributes[.size] as? NSNumber)?.int64Value else {
            throw FileSendError.fileUnreadable
        }
        let chunkCount = fileSize == 0 ? 0 : Int((fileSize + Int64(chunkSize) - 1) / Int64(chunkSize))

        let fileHash: String
        do {
            fileHash = try ContentHasher.fileHash(contentsOf: url)
        } catch {
            throw FileSendError.fileUnreadable
        }

        let transferId = UUID().uuidString.lowercased()
        let fileKey = FileTransferCrypto.deriveFileKey(pairKey: key, transferId: transferId)

        let offer = FileOfferPayload(
            transferId: transferId,
            fileName: url.lastPathComponent,
            fileSize: fileSize,
            mimeType: mimeType,
            fileHash: fileHash,
            chunkSize: chunkSize,
            chunkCount: chunkCount,
            createdAt: Date(),
            sourceDeviceName: identity.name
        )

        // Offer. No cancel needed on failure — nothing is registered on the receiver yet.
        let offerEnvelope = try ClipEnvelope.seal(payload: offer, sourceDeviceId: identity.id, pairKey: key)
        try await post("/v1/file/offer", body: encodeJSON(offerEnvelope), contentType: "application/json", headers: [:], to: peer)

        // Chunks.
        do {
            if isCancelled?() == true { throw FileSendError.cancelled }

            if chunkCount > 0 {
                guard let handle = try? FileHandle(forReadingFrom: url) else {
                    throw FileSendError.fileUnreadable
                }
                defer { try? handle.close() }

                for index in 0..<chunkCount {
                    if isCancelled?() == true { throw FileSendError.cancelled }

                    let slice = (try? handle.read(upToCount: chunkSize)) ?? Data()
                    let sealed = try FileTransferCrypto.sealChunk(slice, fileKey: fileKey, index: UInt64(index))
                    try await post(
                        "/v1/file/chunk",
                        body: sealed,
                        contentType: "application/octet-stream",
                        headers: [
                            FileTransferConstants.transferIdHeader: transferId,
                            FileTransferConstants.chunkIndexHeader: "\(index)"
                        ],
                        to: peer
                    )
                    progress?(Double(index + 1) / Double(chunkCount))
                }
            }

            // Finish.
            let finish = FileFinishPayload(transferId: transferId)
            let finishEnvelope = try ClipEnvelope.seal(payload: finish, sourceDeviceId: identity.id, pairKey: key)
            try await post("/v1/file/finish", body: encodeJSON(finishEnvelope), contentType: "application/json", headers: [:], to: peer)
            progress?(1.0)
        } catch {
            await bestEffortCancel(transferId: transferId, peer: peer, key: key)
            throw error
        }
    }

    // MARK: - Internals

    private func bestEffortCancel(transferId: String, peer: Peer, key: SymmetricKey) async {
        guard let envelope = try? ClipEnvelope.seal(
            payload: FileCancelPayload(transferId: transferId),
            sourceDeviceId: identity.id,
            pairKey: key
        ), let body = try? encodeJSON(envelope) else { return }
        _ = try? await post("/v1/file/cancel", body: body, contentType: "application/json", headers: [:], to: peer)
    }

    @discardableResult
    private func post(
        _ path: String,
        body: Data,
        contentType: String,
        headers: [String: String],
        to peer: Peer
    ) async throws -> HTTPResponse {
        var allHeaders = headers
        allHeaders["Content-Type"] = contentType
        let request = HTTPRequest(method: "POST", path: path, headers: allHeaders, body: body)
        let requestData = HTTPCodec.encodeRequest(request, host: "\(peer.host):\(peer.port)")
        let responseData = try await transport.send(requestData, to: peer)
        let response = try HTTPCodec.parseResponse(responseData)
        guard response.statusCode == 200 else {
            throw FileSendError.httpStatus(endpoint: path, statusCode: response.statusCode)
        }
        return response
    }

    private func encodeJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }
}
