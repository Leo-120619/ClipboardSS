import Foundation
import CryptoKit
@testable import ClipboardCore

/// Mutable clock for driving idle-GC tests.
final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date) { current = start }
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return current }
    func advance(by seconds: TimeInterval) { lock.lock(); current = current.addingTimeInterval(seconds); lock.unlock() }
}

final class FileInMemoryPairKeyStorage: PairKeyStorage, @unchecked Sendable {
    var keys: [UUID: SymmetricKey] = [:]
    func storeKey(_ key: SymmetricKey, for deviceId: UUID) throws { keys[deviceId] = key }
    func getKey(for deviceId: UUID) throws -> SymmetricKey? { keys[deviceId] }
    func deleteKey(for deviceId: UUID) throws { keys[deviceId] = nil }
}

/// Builds a `PairedDeviceStore` holding a single paired peer with the given key.
func makePairedStore(peerId: UUID, key: SymmetricKey) async throws -> PairedDeviceStore {
    let url = try temporaryDirectory().appendingPathComponent("keys.json")
    let store = try PairedDeviceStore(storageURL: url, keyStorage: FileInMemoryPairKeyStorage())
    try await store.addDevice(PairedDevice(id: peerId, name: "Peer"), key: key)
    return store
}

func sealedEnvelope<T: Encodable>(_ payload: T, sourceDeviceId: UUID, key: SymmetricKey) throws -> ClipEnvelope {
    try ClipEnvelope.seal(payload: payload, sourceDeviceId: sourceDeviceId, pairKey: key)
}

/// Records outgoing requests and returns configurable responses keyed by path.
/// Default response is 200 with `{}`.
final class RecordingTransport: PeerTransport, @unchecked Sendable {
    struct Recorded: Sendable {
        let request: HTTPRequest
        let peer: Peer
    }

    private let lock = NSLock()
    private(set) var recorded: [Recorded] = []
    /// Path -> status code override. Missing paths default to 200.
    var statusForPath: [String: Int] = [:]
    /// If set, the Nth call (0-indexed) fails with this status regardless of path.
    var failAtCallIndex: (index: Int, status: Int)?

    var requests: [HTTPRequest] { lock.lock(); defer { lock.unlock() }; return recorded.map(\.request) }

    func send(_ data: Data, to peer: Peer) async throws -> Data {
        let request = try HTTPCodec.parseRequest(data)
        let status = record(request: request, peer: peer)
        return HTTPCodec.encodeResponse(HTTPResponse(statusCode: status, headers: [:], body: Data("{}".utf8)))
    }

    private func record(request: HTTPRequest, peer: Peer) -> Int {
        lock.lock(); defer { lock.unlock() }
        let callIndex = recorded.count
        recorded.append(Recorded(request: request, peer: peer))
        var status = statusForPath[request.path] ?? 200
        if let failure = failAtCallIndex, failure.index == callIndex { status = failure.status }
        return status
    }
}

/// Loops sender requests straight into a real `FileReceiver`, through the real codec.
final class LoopbackTransport: PeerTransport, @unchecked Sendable {
    private let receiver: FileReceiver
    init(receiver: FileReceiver) { self.receiver = receiver }

    func send(_ data: Data, to peer: Peer) async throws -> Data {
        let request = try HTTPCodec.parseRequest(data)
        let response: FileTransferResponse
        switch request.path {
        case "/v1/file/offer":
            response = await receiver.handleOffer(envelope: try decodeEnvelope(request.body))
        case "/v1/file/chunk":
            let transferId = request.headers["x-transfer-id"] ?? ""
            let index = Int(request.headers["x-chunk-index"] ?? "") ?? -1
            response = await receiver.handleChunk(transferId: transferId, chunkIndex: index, body: request.body)
        case "/v1/file/finish":
            response = await receiver.handleFinish(envelope: try decodeEnvelope(request.body))
        case "/v1/file/cancel":
            response = await receiver.handleCancel(envelope: try decodeEnvelope(request.body))
        default:
            response = .status(404)
        }
        return HTTPCodec.encodeResponse(HTTPResponse(statusCode: response.statusCode, headers: [:], body: response.body))
    }

    private func decodeEnvelope(_ data: Data) throws -> ClipEnvelope {
        try JSONDecoder().decode(ClipEnvelope.self, from: data)
    }
}
