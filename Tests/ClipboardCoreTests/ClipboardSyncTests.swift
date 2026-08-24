import Foundation
import Testing
import CryptoKit
@testable import ClipboardCore

@Suite("Clipboard sync")
struct ClipboardSyncTests {
    @Test("Hash parity test vectors")
    func hashParity() {
        let textHash = ContentHasher.textHash("Hello, world!")
        #expect(textHash == "f2860ecbb844a4c152aed2007055a3d41911dcb0fb7a64b996525d5b62a722e1")
        
        let imageHash = ContentHasher.imageHash(Data([1, 2, 3]))
        #expect(imageHash == "1b91e2105a1a014f55e1038235f53eae70458235d3f37da8672b563a21c04929")
    }
    
    @Test("Pairing session")
    func pairingSession() throws {
        let initiator = PairingSession()
        let target = PairingSession()
        
        let iId = UUID()
        let tId = UUID()
        
        let (iKey, iCode) = try initiator.completePairing(remotePublicKey: target.ephemeralPublicKey, initiatorId: iId, targetId: tId, isInitiator: true, code: "000000")
        let (tKey, tCode) = try target.completePairing(remotePublicKey: initiator.ephemeralPublicKey, initiatorId: iId, targetId: tId, isInitiator: false, code: "000000")
        
        #expect(iKey == tKey)
        #expect(iCode == tCode)
        #expect(iCode.count == 6)
        
        let proof = PairingSession.generateConfirmationProof(pairKey: iKey, initiatorId: iId, targetId: tId)
        #expect(PairingSession.verifyConfirmationProof(proof: proof, pairKey: tKey, initiatorId: iId, targetId: tId))
    }

    @Test("Code-bound pairKey differs by code and matches across peers")
    func codeBoundPairing() throws {
        let initiator = PairingSession()
        let target = PairingSession()
        let iId = UUID()
        let tId = UUID()

        let (keyA, _) = try initiator.completePairing(
            remotePublicKey: target.ephemeralPublicKey,
            initiatorId: iId,
            targetId: tId,
            isInitiator: true,
            code: "048213"
        )
        let (keyB, _) = try target.completePairing(
            remotePublicKey: initiator.ephemeralPublicKey,
            initiatorId: iId,
            targetId: tId,
            isInitiator: false,
            code: "048213"
        )
        #expect(keyA == keyB)

        let (keyWrong, _) = try target.completePairing(
            remotePublicKey: initiator.ephemeralPublicKey,
            initiatorId: iId,
            targetId: tId,
            isInitiator: false,
            code: "999999"
        )
        #expect(keyWrong != keyA)
    }

    @Test("Confirmation proof uses lowercase canonical UUID strings")
    func confirmationProofUsesLowercaseCanonicalUUIDStrings() throws {
        let pairKey = SymmetricKey(data: Data(repeating: 0x2A, count: 32))
        let initiatorId = try #require(UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000"))
        let targetId = try #require(UUID(uuidString: "4d967c79-47dc-4e1f-a3bd-d3160b082da7"))

        let proof = PairingSession.generateConfirmationProof(
            pairKey: pairKey,
            initiatorId: initiatorId,
            targetId: targetId
        )

        let expectedMessage = "confirm550e8400-e29b-41d4-a716-4466554400004d967c79-47dc-4e1f-a3bd-d3160b082da7"
        let expected = Data(HMAC<SHA256>.authenticationCode(for: Data(expectedMessage.utf8), using: pairKey))
        #expect(proof == expected)
    }
    
    @Test("Clip envelope round-trip")
    func clipEnvelope() throws {
        let payload = ClipPayload(id: UUID(), type: .text, createdAt: Date(), text: "secret message", previewText: "secret", contentHash: "hash123", sourceDeviceName: "Mac")
        let key = SymmetricKey(size: .bits256)
        
        let envelope = try ClipEnvelope.seal(payload: payload, sourceDeviceId: UUID(), pairKey: key)
        
        let opened = try envelope.open(pairKey: key)
        #expect(opened.text == "secret message")
        
        let wrongKey = SymmetricKey(size: .bits256)
        #expect(throws: EnvelopeError.decryptionFailed) {
            try envelope.open(pairKey: wrongKey)
        }
    }
    
    @Test("HTTP Codec parse request")
    func httpCodec() throws {
        let reqString = "POST /v1/clip HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello"
        let data = Data(reqString.utf8)
        let request = try HTTPCodec.parseRequest(data)
        
        #expect(request.method == "POST")
        #expect(request.path == "/v1/clip")
        #expect(request.headers["content-length"] == "5")
        #expect(String(data: request.body, encoding: .utf8) == "hello")
    }

    @Test("ClipReceiver text payload")
    @MainActor
    func clipReceiverText() async throws {
        let pasteboard = FakePasteboard()
        let store = try ClipStore(storageDirectory: try syncTemporaryDirectory())
        let receiver = await ClipReceiver(store: store, pasteboard: pasteboard)
        
        let payload = ClipPayload(id: UUID(), type: .text, createdAt: Date(), text: "hello net", previewText: "hello net", contentHash: "hashnet", sourceDeviceName: "Phone")
        let result = try await receiver.receive(payload)
        
        if case .added(let clip) = result {
            #expect(clip.text == "hello net")
        } else {
            Issue.record("Expected added")
        }
        
        let items = store.items
        #expect(items.count == 1)
        #expect(items[0].text == "hello net")
        #expect(pasteboard.lastText == "hello net")
    }

    @Test("ClipSender broadcast")
    func clipSenderBroadcast() async throws {
        let pairedStore = try PairedDeviceStore(storageURL: try syncTemporaryDirectory().appendingPathComponent("keys.json"), keyStorage: FakePairKeyStorage())
        let transport = FakePeerTransport()
        let myId = UUID()
        let sender = ClipSender(identity: DeviceIdentity(id: myId, name: "Mac"), pairedStore: pairedStore, transport: transport, storageDirectory: try syncTemporaryDirectory())
        
        let peerId = UUID()
        let key = SymmetricKey(size: .bits256)
        try await pairedStore.addDevice(PairedDevice(id: peerId, name: "Phone"), key: key)
        
        let clip = ClipItem(type: .text, createdAt: Date(), text: "broadcast", previewText: "broadcast", contentHash: "123")
        let peer = Peer(id: peerId, name: "Phone", host: "10.0.0.1", port: 8080)
        
        let result = try await sender.broadcast(clip: clip, to: [peer])
        
        #expect(transport.sentRequests.count == 1)
        #expect(transport.sentRequests[0].1.id == peerId)
        #expect(result.successCount == 1)
        
        let selfPeer = Peer(id: myId, name: "Mac", host: "10.0.0.2", port: 8080)
        let secondResult = try await sender.broadcast(clip: clip, to: [peer, selfPeer])
        #expect(transport.sentRequests.count == 2)
        #expect(secondResult.successCount == 1)
    }

    @Test("ClipSender treats non-200 responses as failed sends")
    func clipSenderChecksResponseStatus() async throws {
        let pairedStore = try PairedDeviceStore(storageURL: try syncTemporaryDirectory().appendingPathComponent("keys.json"), keyStorage: FakePairKeyStorage())
        let transport = FakePeerTransport()
        transport.responseData = HTTPCodec.encodeResponse(
            HTTPResponse(statusCode: 500, headers: [:], body: Data("Nope".utf8))
        )
        let myId = UUID()
        let sender = ClipSender(identity: DeviceIdentity(id: myId, name: "Mac"), pairedStore: pairedStore, transport: transport, storageDirectory: try syncTemporaryDirectory())

        let peerId = UUID()
        try await pairedStore.addDevice(PairedDevice(id: peerId, name: "Phone"), key: SymmetricKey(size: .bits256))

        let clip = ClipItem(type: .text, createdAt: Date(), text: "broadcast", previewText: "broadcast", contentHash: "123")
        let peer = Peer(id: peerId, name: "Phone", host: "10.0.0.1", port: 8080)

        let result = try await sender.broadcast(clip: clip, to: [peer])
        #expect(result.successCount == 0)
        #expect(result.failureCount == 1)
    }
}

private final class FakePasteboard: PasteboardClient, @unchecked Sendable {
    var changeCount = 0
    var snapshot = ClipboardSnapshot(text: nil, imageData: nil)
    var clearCount = 0
    var lastText: String?
    var lastImageData: Data?

    func currentChangeCount() -> Int {
        changeCount
    }

    func readSnapshot() -> ClipboardSnapshot {
        snapshot
    }

    func clearContents() {
        clearCount += 1
        lastText = nil
        lastImageData = nil
    }

    func writeText(_ text: String) {
        lastText = text
    }

    func writeImageData(_ data: Data) {
        lastImageData = data
    }
}

private final class FakePairKeyStorage: PairKeyStorage, @unchecked Sendable {
    var keys: [UUID: SymmetricKey] = [:]
    
    func storeKey(_ key: SymmetricKey, for deviceId: UUID) throws {
        keys[deviceId] = key
    }
    
    func getKey(for deviceId: UUID) throws -> SymmetricKey? {
        keys[deviceId]
    }
    
    func deleteKey(for deviceId: UUID) throws {
        keys[deviceId] = nil
    }
}

private final class FakePeerTransport: PeerTransport, @unchecked Sendable {
    var sentRequests: [(Data, Peer)] = []
    var shouldFail: Bool = false
    var responseData = HTTPCodec.encodeResponse(
        HTTPResponse(statusCode: 200, headers: [:], body: Data("OK".utf8))
    )
    
    func send(_ data: Data, to peer: Peer) async throws -> Data {
        if shouldFail { throw URLError(.cannotConnectToHost) }
        sentRequests.append((data, peer))
        return responseData
    }
}

private func syncTemporaryDirectory() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
