import Foundation
import CryptoKit

public struct Peer: Equatable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let host: String
    public let port: UInt16
    
    public init(id: UUID, name: String, host: String, port: UInt16) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
    }
}

public protocol PeerTransport: Sendable {
    func send(_ data: Data, to peer: Peer) async throws -> Data
}

public enum SendError: Error {
    case noPairedPeers
    case someFailed([Peer: Error])
}

public struct ClipSendResult: Equatable, Sendable {
    public let visiblePeerCount: Int
    public let pairedPeerCount: Int
    public let successCount: Int
    public let failureCount: Int

    public init(visiblePeerCount: Int, pairedPeerCount: Int, successCount: Int, failureCount: Int) {
        self.visiblePeerCount = visiblePeerCount
        self.pairedPeerCount = pairedPeerCount
        self.successCount = successCount
        self.failureCount = failureCount
    }

    public var hasVisiblePeers: Bool { visiblePeerCount > 0 }
    public var hasPairedTargets: Bool { pairedPeerCount > 0 }
}

public struct ClipSendHTTPStatusError: Error, Equatable, Sendable {
    public let statusCode: Int

    public init(statusCode: Int) {
        self.statusCode = statusCode
    }
}

public struct ClipSender: Sendable {
    private let identity: DeviceIdentity
    public let pairedStore: PairedDeviceStore
    private let transport: PeerTransport
    private let storageDirectory: URL
    
    public init(identity: DeviceIdentity, pairedStore: PairedDeviceStore, transport: PeerTransport, storageDirectory: URL) {
        self.identity = identity
        self.pairedStore = pairedStore
        self.transport = transport
        self.storageDirectory = storageDirectory
    }
    
    public func broadcast(clip: ClipItem, to peers: [Peer]) async throws -> ClipSendResult {
        let targets = peers.filter { $0.id != identity.id }
        if targets.isEmpty {
            return ClipSendResult(visiblePeerCount: 0, pairedPeerCount: 0, successCount: 0, failureCount: 0)
        }
        
        var pairedTargets: [(Peer, SymmetricKey)] = []
        for peer in targets {
            if let key = try? await pairedStore.getKey(for: peer.id) {
                pairedTargets.append((peer, key))
            }
        }
        
        if pairedTargets.isEmpty {
            return ClipSendResult(visiblePeerCount: targets.count, pairedPeerCount: 0, successCount: 0, failureCount: 0)
        }
        
        var imageBase64: String? = nil
        var imageExtension: String? = nil
        
        if clip.type == .image, let path = clip.imagePath {
            let fileURL = storageDirectory.appendingPathComponent(path)
            let data = try Data(contentsOf: fileURL)
            imageBase64 = data.base64EncodedString()
            imageExtension = fileURL.pathExtension
        }
        
        let payload = ClipPayload(
            id: clip.id,
            type: clip.type,
            createdAt: clip.createdAt,
            text: clip.text,
            imageBase64: imageBase64,
            imageExtension: imageExtension,
            previewText: clip.previewText,
            contentHash: clip.contentHash,
            sourceDeviceName: identity.name
        )
        
        return try await withThrowingTaskGroup(of: (Peer, Error?).self) { group in
            for (peer, key) in pairedTargets {
                group.addTask {
                    do {
                        let envelope = try ClipEnvelope.seal(payload: payload, sourceDeviceId: identity.id, pairKey: key)
                        let encoder = JSONEncoder()
                        encoder.dateEncodingStrategy = .iso8601
                        let envelopeData = try encoder.encode(envelope)
                        
                        let request = HTTPRequest(
                            method: "POST",
                            path: "/v1/clip",
                            headers: ["Content-Type": "application/json"],
                            body: envelopeData
                        )
                        let requestData = HTTPCodec.encodeRequest(request, host: "\(peer.host):\(peer.port)")
                        let responseData = try await transport.send(requestData, to: peer)
                        let response = try HTTPCodec.parseResponse(responseData)
                        guard response.statusCode == 200 else {
                            throw ClipSendHTTPStatusError(statusCode: response.statusCode)
                        }
                        return (peer, nil)
                    } catch {
                        return (peer, error)
                    }
                }
            }
            
            var failures: [Peer: Error] = [:]
            for try await (peer, error) in group {
                if let error = error {
                    failures[peer] = error
                }
            }

            return ClipSendResult(
                visiblePeerCount: targets.count,
                pairedPeerCount: pairedTargets.count,
                successCount: pairedTargets.count - failures.count,
                failureCount: failures.count
            )
        }
    }
}
