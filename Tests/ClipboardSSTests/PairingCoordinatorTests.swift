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
        #expect(harness.coordinator.hostComparison == nil)

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
        harness.coordinator.confirmHostedPairing()

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
        #expect(harness.coordinator.hostComparison == nil)
        let outcome = try await harness.coordinator.handlePairConfirmRequest(
            initiatorId: harness.initiatorA,
            proofBase64: initiator.proof.base64EncodedString()
        )
        #expect(outcome == .rejected)
        #expect(try await harness.pairedStore.getKey(for: harness.initiatorA) == nil)
    }

    @Test("a second start from another device ends the code")
    func secondInitiatorWhilePendingEndsCode() async throws {
        let harness = try PairingHarness()
        let code = harness.coordinator.startHosting()
        let first = try await harness.start(initiatorId: harness.initiatorA, code: code)

        await #expect(throws: PairingError.self) {
            _ = try await harness.startWithoutReveal(initiatorId: harness.initiatorB)
        }
        #expect(harness.coordinator.hostCode == nil)
        #expect(harness.coordinator.hostComparison == nil)

        harness.coordinator.confirmHostedPairing()
        let outcome = try await harness.coordinator.handlePairConfirmRequest(
            initiatorId: harness.initiatorA,
            proofBase64: first.proof.base64EncodedString()
        )
        #expect(outcome == .rejected)
        #expect(try await harness.pairedStore.getKey(for: harness.initiatorA) == nil)
    }

    @Test("a code hands out one target key: a second start from the same device ends it")
    func secondStartFromSameInitiatorEndsCode() async throws {
        let harness = try PairingHarness()
        _ = harness.coordinator.startHosting()
        let started = try await harness.startWithoutReveal(initiatorId: harness.initiatorA)

        await #expect(throws: PairingError.self) {
            _ = try await harness.startWithoutReveal(initiatorId: harness.initiatorA)
        }
        #expect(harness.coordinator.hostCode == nil)
        let reveal = harness.coordinator.handlePairRevealRequest(
            initiatorId: harness.initiatorA,
            initiatorPubKeyBase64: started.session.ephemeralPublicKey.base64EncodedString(),
            saltBase64: started.salt.base64EncodedString()
        )
        #expect(reveal == .rejected)
    }

    @Test("a confirm for an already paired deviceId is rejected and keeps the stored key")
    func confirmForAlreadyPairedDeviceIdIsRejected() async throws {
        let harness = try PairingHarness()
        let existingKey = SymmetricKey(size: .bits256)
        try await harness.pairedStore.addDevice(PairedDevice(id: harness.initiatorA, name: "Existing"), key: existingKey)

        let code = harness.coordinator.startHosting()
        let initiator = try await harness.start(initiatorId: harness.initiatorA, code: code)
        harness.coordinator.confirmHostedPairing()
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
        #expect(harness.coordinator.hostComparison == nil)

        // The stale initiator no longer occupies the new code...
        _ = try await harness.start(initiatorId: harness.initiatorB, code: newCode)

        // ...and its old proof cannot complete pairing.
        harness.coordinator.confirmHostedPairing()
        let outcome = try await harness.coordinator.handlePairConfirmRequest(
            initiatorId: harness.initiatorA,
            proofBase64: stale.proof.base64EncodedString()
        )
        #expect(outcome == .rejected)
        #expect(try await harness.pairedStore.getKey(for: harness.initiatorA) == nil)
    }

    @Test("a reveal whose key does not match the commitment invalidates the code")
    func revealWithWrongKeyInvalidatesCode() async throws {
        let harness = try PairingHarness()
        let code = harness.coordinator.startHosting()
        let started = try await harness.startWithoutReveal(initiatorId: harness.initiatorA)

        let otherKey = PairingSession().ephemeralPublicKey
        let outcome = harness.coordinator.handlePairRevealRequest(
            initiatorId: harness.initiatorA,
            initiatorPubKeyBase64: otherKey.base64EncodedString(),
            saltBase64: started.salt.base64EncodedString()
        )
        #expect(outcome == .invalid)
        #expect(harness.coordinator.hostCode == nil)
        #expect(harness.coordinator.hostComparison == nil)

        // The honest reveal is now refused too, and so is a fresh start on the same code.
        let honest = harness.coordinator.handlePairRevealRequest(
            initiatorId: harness.initiatorA,
            initiatorPubKeyBase64: started.session.ephemeralPublicKey.base64EncodedString(),
            saltBase64: started.salt.base64EncodedString()
        )
        #expect(honest == .rejected)
        await #expect(throws: PairingError.self) {
            _ = try await harness.start(initiatorId: harness.initiatorA, code: code)
        }
    }

    @Test("keys are stored only after both users confirmed the number")
    func keysAreNotStoredUntilBothConfirm() async throws {
        let target = try PairingHarness()
        let initiator = try PairingHarness(transport: LoopbackPairingTransport(target: target.coordinator))
        let code = target.coordinator.startHosting()
        let peer = Peer(id: target.identity.id, name: target.identity.name, host: "10.0.0.2", port: 51888)

        let comparison = try await initiator.coordinator.startPairing(with: peer, code: code)
        let hosted = try #require(target.coordinator.hostComparison)
        #expect(comparison.confirmCode == hosted.confirmCode)
        #expect(comparison.deviceName == target.identity.name)
        #expect(hosted.deviceName == initiator.identity.name)
        #expect(initiator.coordinator.joinComparison == comparison)
        #expect(await initiator.pairedStore.devices.isEmpty)
        #expect(await target.pairedStore.devices.isEmpty)

        // The initiator's user confirms; the target holds the request for its own user.
        let confirming = Task { try await initiator.coordinator.confirmPairing() }
        try await target.waitUntilConfirmIsHeld()
        #expect(await initiator.pairedStore.devices.isEmpty)
        #expect(await target.pairedStore.devices.isEmpty)

        target.coordinator.confirmHostedPairing()
        try await confirming.value

        let initiatorKey = try #require(try await initiator.pairedStore.getKey(for: target.identity.id))
        let targetKey = try #require(try await target.pairedStore.getKey(for: initiator.identity.id))
        #expect(initiatorKey == targetKey)
        #expect(target.coordinator.hostComparison == nil)
        #expect(initiator.coordinator.joinComparison == nil)
    }

    @Test("cancelling on the target rejects the initiator and stores nothing on either side")
    func targetCancelRejectsInitiator() async throws {
        let target = try PairingHarness()
        let initiator = try PairingHarness(transport: LoopbackPairingTransport(target: target.coordinator))
        let code = target.coordinator.startHosting()
        let peer = Peer(id: target.identity.id, name: target.identity.name, host: "10.0.0.2", port: 51888)

        _ = try await initiator.coordinator.startPairing(with: peer, code: code)
        let confirming = Task { try await initiator.coordinator.confirmPairing() }
        try await target.waitUntilConfirmIsHeld()
        target.coordinator.cancelHostedPairing()

        await #expect(throws: PairingError.rejected) { try await confirming.value }
        #expect(await initiator.pairedStore.devices.isEmpty)
        #expect(await target.pairedStore.devices.isEmpty)
        #expect(target.coordinator.hostCode == nil)
        #expect(target.coordinator.hostComparison == nil)
        #expect(initiator.coordinator.joinComparison == nil)
    }

    @Test("cancelling on the initiator after confirming stores nothing on either side")
    func initiatorCancelAfterConfirmStoresNothing() async throws {
        let target = try PairingHarness()
        let initiator = try PairingHarness(transport: LoopbackPairingTransport(target: target.coordinator))
        let code = target.coordinator.startHosting()
        let peer = Peer(id: target.identity.id, name: target.identity.name, host: "10.0.0.2", port: 51888)

        _ = try await initiator.coordinator.startPairing(with: peer, code: code)
        let confirming = Task { try await initiator.coordinator.confirmPairing() }
        try await target.waitUntilConfirmIsHeld()
        await initiator.coordinator.cancelPairing()?.value
        target.coordinator.confirmHostedPairing()

        await #expect(throws: PairingError.cancelled) { try await confirming.value }
        #expect(await initiator.pairedStore.devices.isEmpty)
        #expect(await target.pairedStore.devices.isEmpty)
        #expect(target.coordinator.hostCode == nil)
        #expect(target.coordinator.hostComparison == nil)
        #expect(initiator.coordinator.joinComparison == nil)
    }

    @Test("the target confirms first, then the initiator: both store the key")
    func targetConfirmsFirstThenInitiatorConfirms() async throws {
        let target = try PairingHarness()
        let initiator = try PairingHarness(transport: LoopbackPairingTransport(target: target.coordinator))
        let code = target.coordinator.startHosting()
        let peer = Peer(id: target.identity.id, name: target.identity.name, host: "10.0.0.2", port: 51888)

        _ = try await initiator.coordinator.startPairing(with: peer, code: code)
        target.coordinator.confirmHostedPairing()
        #expect(target.coordinator.hostComparison?.localConfirmed == true)
        try await initiator.coordinator.confirmPairing()

        let initiatorKey = try #require(try await initiator.pairedStore.getKey(for: target.identity.id))
        #expect(try await target.pairedStore.getKey(for: initiator.identity.id) == initiatorKey)
        #expect(!target.coordinator.isHoldingConfirm)
    }

    @Test("the initiator only contacts the device the user selected")
    func initiatorOnlyContactsSelectedPeer() async throws {
        let target = try PairingHarness()
        let loopback = LoopbackPairingTransport(target: target.coordinator)
        let initiator = try PairingHarness(transport: loopback)
        let code = target.coordinator.startHosting()
        let selected = Peer(id: target.identity.id, name: target.identity.name, host: "10.0.0.2", port: 51888)

        _ = try await initiator.coordinator.startPairing(with: selected, code: code)
        target.coordinator.confirmHostedPairing()
        try await initiator.coordinator.confirmPairing()

        #expect(loopback.requests.map(\.path) == ["/v1/pair/start", "/v1/pair/reveal", "/v1/pair/confirm"])
        #expect(Set(loopback.requests.map(\.host)) == ["10.0.0.2"])
        // The target may hold the confirm for 60 s, so only it gets the long timeout.
        #expect(loopback.requests.map(\.timeout) == [10, 10, PairingCoordinator.confirmRequestTimeout])
    }

    @Test("a held confirm times out after 60 s with 408 and ends the code")
    func confirmTimesOutAfter60s() async throws {
        #expect(PairingCoordinator.confirmHoldTimeout == 60)
        let harness = try PairingHarness(confirmHoldTimeout: 0.05)
        let code = harness.coordinator.startHosting()
        let initiator = try await harness.start(initiatorId: harness.initiatorA, code: code)

        let outcome = try await harness.coordinator.handlePairConfirmRequest(
            initiatorId: harness.initiatorA,
            proofBase64: initiator.proof.base64EncodedString()
        )
        #expect(outcome == .timedOut)
        #expect(harness.coordinator.hostCode == nil)
        #expect(harness.coordinator.hostComparison == nil)
        #expect(try await harness.pairedStore.getKey(for: harness.initiatorA) == nil)
    }

    @Test("an expired code is cleared for the UI without any request")
    func expiredCodeIsClearedWithoutARequest() async throws {
        let harness = try PairingHarness()
        _ = harness.coordinator.startHosting(ttl: 0.05)
        harness.clock.advance(by: 1)
        for _ in 0..<100 where harness.coordinator.hostCode != nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(harness.coordinator.hostCode == nil)
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
            HTTPCodec.encodeResponse(HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: Data(#"{"status":"ok"}"#.utf8))),
            HTTPCodec.encodeResponse(HTTPResponse(statusCode: 409, headers: ["Content-Type": "application/json"], body: Data(#"{"status":"alreadyPaired"}"#.utf8))),
        ])
        let harness = try PairingHarness(transport: transport)

        _ = try await harness.coordinator.startPairing(with: Peer(id: target.id, name: target.name, host: "10.0.0.2", port: 51888), code: "123456")
        await #expect(throws: PairingError.alreadyPaired) {
            try await harness.coordinator.confirmPairing()
        }
        #expect(await harness.pairedStore.devices.isEmpty)
        #expect(harness.coordinator.joinComparison == nil)
    }
}

@MainActor
private final class PairingHarness {
    let identity = DeviceIdentity(id: UUID(), name: "Test Mac \(UUID().uuidString.prefix(4))")
    let initiatorA = UUID()
    let initiatorB = UUID()
    let clock = TestClock()
    let pairedStore: PairedDeviceStore
    let coordinator: PairingCoordinator

    struct Initiation {
        let pairKey: SymmetricKey
        let proof: Data
    }

    struct Started {
        let session: PairingSession
        let salt: Data
        let targetPublicKey: Data
    }

    init(transport: PeerTransport = UnusedPeerTransport(), confirmHoldTimeout: TimeInterval = PairingCoordinator.confirmHoldTimeout) throws {
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
            confirmHoldTimeout: confirmHoldTimeout,
            now: { clock.now }
        )
    }

    /// Plays the initiator side of `/v1/pair/start` only: a commitment to a fresh key.
    func startWithoutReveal(initiatorId: UUID) async throws -> Started {
        let session = PairingSession()
        let salt = PairingSession.randomSalt()
        let targetPublicKey = try await coordinator.handlePairStartRequest(
            initiatorId: initiatorId,
            initiatorName: "Initiator",
            commitmentBase64: PairingSession.commitment(publicKey: session.ephemeralPublicKey, salt: salt).base64EncodedString(),
            remoteHost: "10.0.0.9"
        )
        return Started(session: session, salt: salt, targetPublicKey: targetPublicKey)
    }

    /// Plays `/v1/pair/start` and `/v1/pair/reveal`, and derives the proof the initiator would send to `/v1/pair/confirm`.
    func start(initiatorId: UUID, code: String) async throws -> Initiation {
        let started = try await startWithoutReveal(initiatorId: initiatorId)
        let reveal = coordinator.handlePairRevealRequest(
            initiatorId: initiatorId,
            initiatorPubKeyBase64: started.session.ephemeralPublicKey.base64EncodedString(),
            saltBase64: started.salt.base64EncodedString()
        )
        guard reveal == .ok else { throw PairingError.rejected }
        let (pairKey, _) = try started.session.completePairing(
            remotePublicKey: started.targetPublicKey,
            isInitiator: true,
            code: code
        )
        let proof = PairingSession.generateConfirmationProof(pairKey: pairKey, initiatorId: initiatorId, targetId: identity.id)
        return Initiation(pairKey: pairKey, proof: proof)
    }

    /// Waits until a `/v1/pair/confirm` has arrived and is waiting for this device's user.
    func waitUntilConfirmIsHeld() async throws {
        for _ in 0..<500 where !coordinator.isHoldingConfirm {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        #expect(coordinator.isHoldingConfirm)
    }
}

/// Delivers each pairing request to a target coordinator in-process, recording where it was sent.
@MainActor
private final class LoopbackPairingTransport: PeerTransport, @unchecked Sendable {
    let target: PairingCoordinator
    private(set) var requests: [(host: String, path: String, timeout: TimeInterval)] = []

    init(target: PairingCoordinator) { self.target = target }

    nonisolated func send(_ data: Data, to peer: Peer, timeout: TimeInterval) async throws -> Data {
        try await deliver(data, to: peer, timeout: timeout)
    }

    private func deliver(_ data: Data, to peer: Peer, timeout: TimeInterval) async throws -> Data {
        let request = try HTTPCodec.parseRequest(data)
        requests.append((peer.host, request.path, timeout))
        let response = await target.respond(toPairRequest: request, remoteHost: "10.0.0.9")
        return HTTPCodec.encodeResponse(response)
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
    func send(_ data: Data, to peer: Peer, timeout: TimeInterval) async throws -> Data { Data() }
}

/// Replies to each request with the next canned HTTP response.
private final class ScriptedPeerTransport: PeerTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [Data]
    init(responses: [Data]) { self.responses = responses }
    func send(_ data: Data, to peer: Peer, timeout: TimeInterval) async throws -> Data {
        lock.withLock { responses.removeFirst() }
    }
}
