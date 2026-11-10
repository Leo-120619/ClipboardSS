import Foundation
import Testing
import ClipboardCore
import CryptoKit
@testable import ClipboardSS

@MainActor
@Suite("PairingCoordinator hosting rules")
struct PairingCoordinatorTests {
    @Test("a confirm with a wrong proof invalidates the hosted code")
    func confirmWithWrongProofInvalidatesCode() async throws {
        let harness = try PairingHarness()
        let code = harness.coordinator.startHosting()
        let initiator = try await harness.start(initiatorId: harness.initiatorA, code: code)

        let wrong = try await harness.coordinator.handlePairConfirmRequest(
            initiatorId: harness.initiatorA,
            proofBase64: Data(repeating: 0, count: 32).base64EncodedString()
        )
        #expect(wrong == .rejected)
        #expect(harness.coordinator.hostCode == nil)

        // The correct proof no longer works, and a fresh start is refused: the user must generate a new code.
        let retry = try await harness.coordinator.handlePairConfirmRequest(
            initiatorId: harness.initiatorA,
            proofBase64: initiator.proof.base64EncodedString()
        )
        #expect(retry == .rejected)
        await #expect(throws: PairingError.self) {
            _ = try await harness.start(initiatorId: harness.initiatorA, code: code)
        }
        #expect(try await harness.pairedStore.getKey(for: harness.initiatorA) == nil)
    }

    @Test("a confirm after the code expires is rejected")
    func confirmAfterCodeExpiryIsRejected() async throws {
        let harness = try PairingHarness()
        let code = harness.coordinator.startHosting(ttl: 180)
        let initiator = try await harness.start(initiatorId: harness.initiatorA, code: code)

        harness.clock.advance(by: 181)
        let outcome = try await harness.coordinator.handlePairConfirmRequest(
            initiatorId: harness.initiatorA,
            proofBase64: initiator.proof.base64EncodedString()
        )
        #expect(outcome == .rejected)
        #expect(try await harness.pairedStore.getKey(for: harness.initiatorA) == nil)
    }

    @Test("a confirm after hosting stops is rejected")
    func confirmAfterStopHostingIsRejected() async throws {
        let harness = try PairingHarness()
        let code = harness.coordinator.startHosting()
        let initiator = try await harness.start(initiatorId: harness.initiatorA, code: code)

        harness.coordinator.stopHosting()
        let outcome = try await harness.coordinator.handlePairConfirmRequest(
            initiatorId: harness.initiatorA,
            proofBase64: initiator.proof.base64EncodedString()
        )
        #expect(outcome == .rejected)
        #expect(try await harness.pairedStore.getKey(for: harness.initiatorA) == nil)
    }

    @Test("a second initiator is refused while one is pending")
    func secondInitiatorWhilePendingIsRejected() async throws {
        let harness = try PairingHarness()
        let code = harness.coordinator.startHosting()
        let first = try await harness.start(initiatorId: harness.initiatorA, code: code)

        await #expect(throws: PairingError.self) {
            _ = try await harness.start(initiatorId: harness.initiatorB, code: code)
        }

        // The refused start did not displace the pending initiator.
        let outcome = try await harness.coordinator.handlePairConfirmRequest(
            initiatorId: harness.initiatorA,
            proofBase64: first.proof.base64EncodedString()
        )
        #expect(outcome == .paired)
        #expect(try await harness.pairedStore.getKey(for: harness.initiatorA) == first.pairKey)
    }

    @Test("the same initiator may restart while pending")
    func secondStartFromSameInitiatorReplacesPending() async throws {
        let harness = try PairingHarness()
        let code = harness.coordinator.startHosting()
        _ = try await harness.start(initiatorId: harness.initiatorA, code: code)
        let second = try await harness.start(initiatorId: harness.initiatorA, code: code)

        let outcome = try await harness.coordinator.handlePairConfirmRequest(
            initiatorId: harness.initiatorA,
            proofBase64: second.proof.base64EncodedString()
        )
        #expect(outcome == .paired)
        #expect(try await harness.pairedStore.getKey(for: harness.initiatorA) == second.pairKey)
    }

    @Test("a confirm for an already paired deviceId is rejected and keeps the stored key")
    func confirmForAlreadyPairedDeviceIdIsRejected() async throws {
        let harness = try PairingHarness()
        let existingKey = SymmetricKey(size: .bits256)
        try await harness.pairedStore.addDevice(PairedDevice(id: harness.initiatorA, name: "Existing"), key: existingKey)

        let code = harness.coordinator.startHosting()
        let initiator = try await harness.start(initiatorId: harness.initiatorA, code: code)
        let outcome = try await harness.coordinator.handlePairConfirmRequest(
            initiatorId: harness.initiatorA,
            proofBase64: initiator.proof.base64EncodedString()
        )

        #expect(outcome == .alreadyPaired)
        #expect(try await harness.pairedStore.getKey(for: harness.initiatorA) == existingKey)
        #expect(await harness.pairedStore.devices.map(\.name) == ["Existing"])
    }

    @Test("starting to host again clears the previous pending initiator")
    func startHostingClearsPreviousPendingState() async throws {
        let harness = try PairingHarness()
        let oldCode = harness.coordinator.startHosting()
        let stale = try await harness.start(initiatorId: harness.initiatorA, code: oldCode)

        let newCode = harness.coordinator.startHosting()

        // The stale initiator no longer occupies the new code...
        _ = try await harness.start(initiatorId: harness.initiatorB, code: newCode)

        // ...and its old proof cannot complete pairing.
        let outcome = try await harness.coordinator.handlePairConfirmRequest(
            initiatorId: harness.initiatorA,
            proofBase64: stale.proof.base64EncodedString()
        )
        #expect(outcome == .rejected)
        #expect(try await harness.pairedStore.getKey(for: harness.initiatorA) == nil)
    }

    @Test("the initiator surfaces a 409 from confirm as alreadyPaired")
    func initiatorSurfacesAlreadyPairedConflict() async throws {
        let target = DeviceIdentity(id: UUID(), name: "Phone")
        let startBody = try JSONSerialization.data(withJSONObject: [
            "deviceId": target.id.uuidString,
            "deviceName": target.name,
            "ephemeralPublicKey": PairingSession().ephemeralPublicKey.base64EncodedString(),
        ])
        let transport = ScriptedPeerTransport(responses: [
            HTTPCodec.encodeResponse(HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: startBody)),
            HTTPCodec.encodeResponse(HTTPResponse(statusCode: 409, headers: ["Content-Type": "application/json"], body: Data(#"{"status":"alreadyPaired"}"#.utf8))),
        ])
        let harness = try PairingHarness(transport: transport)

        await #expect(throws: PairingError.alreadyPaired) {
            try await harness.coordinator.startPairing(with: Peer(id: target.id, name: target.name, host: "10.0.0.2", port: 51888), code: "123456")
        }
        #expect(await harness.pairedStore.devices.isEmpty)
    }
}

@MainActor
private final class PairingHarness {
    let identity = DeviceIdentity(id: UUID(), name: "Test Mac")
    let initiatorA = UUID()
    let initiatorB = UUID()
    let clock = TestClock()
    let pairedStore: PairedDeviceStore
    let coordinator: PairingCoordinator

    struct Initiation {
        let pairKey: SymmetricKey
        let proof: Data
    }

    init(transport: PeerTransport = UnusedPeerTransport()) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        pairedStore = try PairedDeviceStore(
            storageURL: directory.appendingPathComponent("paired-devices.json"),
            keyStorage: InMemoryPairKeyStorage()
        )
        let clock = clock
        coordinator = PairingCoordinator(
            identity: identity,
            pairedStore: pairedStore,
            transport: transport,
            now: { clock.now }
        )
    }

    /// Plays the initiator side of `/v1/pair/start` and derives the proof it would send to `/v1/pair/confirm`.
    func start(initiatorId: UUID, code: String) async throws -> Initiation {
        let session = PairingSession()
        let targetPublicKey = try await coordinator.handlePairStartRequest(
            initiatorId: initiatorId,
            initiatorName: "Initiator",
            initiatorPubKeyBase64: session.ephemeralPublicKey.base64EncodedString(),
            remoteHost: "10.0.0.9"
        )
        let (pairKey, _) = try session.completePairing(
            remotePublicKey: targetPublicKey,
            initiatorId: initiatorId,
            targetId: identity.id,
            isInitiator: true,
            code: code
        )
        let proof = PairingSession.generateConfirmationProof(pairKey: pairKey, initiatorId: initiatorId, targetId: identity.id)
        return Initiation(pairKey: pairKey, proof: proof)
    }
}

private final class TestClock: @unchecked Sendable {
    private(set) var now = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(by interval: TimeInterval) { now = now.addingTimeInterval(interval) }
}

private final class InMemoryPairKeyStorage: PairKeyStorage, @unchecked Sendable {
    private var keys: [UUID: SymmetricKey] = [:]
    func storeKey(_ key: SymmetricKey, for deviceId: UUID) throws { keys[deviceId] = key }
    func getKey(for deviceId: UUID) throws -> SymmetricKey? { keys[deviceId] }
    func deleteKey(for deviceId: UUID) throws { keys[deviceId] = nil }
}

private struct UnusedPeerTransport: PeerTransport {
    func send(_ data: Data, to peer: Peer) async throws -> Data { Data() }
}

/// Replies to each request with the next canned HTTP response.
private final class ScriptedPeerTransport: PeerTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [Data]
    init(responses: [Data]) { self.responses = responses }
    func send(_ data: Data, to peer: Peer) async throws -> Data {
        lock.withLock { responses.removeFirst() }
    }
}
