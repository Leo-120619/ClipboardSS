import Foundation
import Network
import Testing
import ClipboardCore
import CryptoKit
@testable import ClipboardSS

@Suite("ClipServer Bonjour TXT sanitization")
struct ClipServerTests {
    @Test("passes through plain ASCII names unchanged")
    func passesThroughAsciiNames() {
        #expect(ClipServer.bonjourSafeTXTValue("Android Device") == "Android Device")
    }

    @Test("replaces curly quotes with straight ASCII equivalents")
    func replacesCurlyQuotes() {
        // macOS computer names commonly use U+2019 (RIGHT SINGLE QUOTATION MARK),
        // which some Android mDNS/NsdManager stacks fail to parse in TXT records,
        // silently hiding the service from discovery.
        #expect(ClipServer.bonjourSafeTXTValue("Leonardo\u{2019}s MacBook") == "Leonardo's MacBook")
    }

    @Test("strips other non-ASCII characters rather than emitting raw UTF-8")
    func stripsOtherNonAsciiCharacters() {
        #expect(ClipServer.bonjourSafeTXTValue("Café ☕") == "Caf ")
    }

    @Test("identity response JSON contains id, name, v")
    func identityResponseJSON() throws {
        let json = ClipServer.identityResponseBody(
            id: UUID(uuidString: "8fb5790c-4533-47bb-90af-827291247fe1")!,
            name: "Mac"
        )
        let obj = try JSONSerialization.jsonObject(with: json) as! [String: Any]
        #expect(obj["deviceId"] as? String == "8FB5790C-4533-47BB-90AF-827291247FE1")
        #expect(obj["deviceName"] as? String == "Mac")
        #expect(obj["v"] as? Int == 2)
    }

    @Test("remoteHost extracts ipv4 without zone")
    func remoteHostParsing() {
        let ep = NWEndpoint.hostPort(host: .ipv4(IPv4Address("192.168.0.9")!), port: 51888)
        #expect(ClipServer.remoteHost(from: ep) == "192.168.0.9")
    }

    @Test("listener retry delay backs off and caps")
    func listenerRetryDelay() {
        #expect(ClipServer.retryDelaySeconds(failureCount: 1) == 1)
        #expect(ClipServer.retryDelaySeconds(failureCount: 2) == 2)
        #expect(ClipServer.retryDelaySeconds(failureCount: 3) == 4)
        #expect(ClipServer.retryDelaySeconds(failureCount: 8) == 30)
    }

    @Test("idle connection that never sends a full request is closed after the deadline")
    @MainActor
    func testIdleConnectionIsClosedAfterDeadline() async throws {
        let harness = try ClipServerHarness(requestDeadline: 0.3)
        defer { harness.server.stop() }
        let port = try await harness.start()

        let outcome = await ClipServerHarness.exchange(port: port, payload: nil, timeout: 3)
        #expect(outcome.closedByServer, "server should close an idle connection after its deadline")
        #expect(outcome.elapsed < 2.5)
    }

    @Test("oversized headers get 431 and the connection is closed")
    @MainActor
    func testOversizedHeadersGet431() async throws {
        let harness = try ClipServerHarness(requestDeadline: 5)
        defer { harness.server.stop() }
        let port = try await harness.start()

        let payload = Data(repeating: UInt8(ascii: "A"), count: HTTPCodec.maxHeaderSize + 1024)
        let outcome = await ClipServerHarness.exchange(port: port, payload: payload, timeout: 3)
        #expect(outcome.closedByServer)
        let response = try HTTPCodec.parseResponse(outcome.received)
        #expect(response.statusCode == 431)
    }

    @Test("a pair confirm held for the user outlives the request deadline")
    @MainActor
    func heldPairConfirmOutlivesRequestDeadline() async throws {
        let harness = try ClipServerHarness(requestDeadline: 0.2)
        defer { harness.server.stop() }
        let port = try await harness.start()

        let code = harness.coordinator.startHosting()
        let initiatorId = UUID()
        let session = PairingSession()
        let salt = PairingSession.randomSalt()
        let targetPublicKey = try await harness.coordinator.handlePairStartRequest(
            initiatorId: initiatorId,
            initiatorName: "Phone",
            commitmentBase64: PairingSession.commitment(publicKey: session.ephemeralPublicKey, salt: salt).base64EncodedString(),
            remoteHost: "127.0.0.1"
        )
        #expect(harness.coordinator.handlePairRevealRequest(
            initiatorId: initiatorId,
            initiatorPubKeyBase64: session.ephemeralPublicKey.base64EncodedString(),
            saltBase64: salt.base64EncodedString()
        ) == .ok)
        let (pairKey, _) = try session.completePairing(remotePublicKey: targetPublicKey, isInitiator: true, code: code)
        let proof = PairingSession.generateConfirmationProof(pairKey: pairKey, initiatorId: initiatorId, targetId: harness.identity.id)
        let body = try JSONSerialization.data(withJSONObject: [
            "deviceId": initiatorId.uuidString.lowercased(),
            "proof": proof.base64EncodedString(),
        ])
        let request = HTTPRequest(method: "POST", path: "/v1/pair/confirm", headers: ["Content-Type": "application/json"], body: body)

        let coordinator = harness.coordinator
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            coordinator.confirmHostedPairing()
        }
        let outcome = await ClipServerHarness.exchange(
            port: port,
            payload: HTTPCodec.encodeRequest(request, host: "127.0.0.1:\(port.rawValue)"),
            timeout: 5
        )
        #expect(outcome.elapsed > 0.5)
        #expect(try HTTPCodec.parseResponse(outcome.received).statusCode == 200)
    }

    @Test("v1 envelopes get 426 upgradeRequired on every envelope endpoint",
          arguments: ["/v1/clip", "/v1/file/offer", "/v1/file/finish", "/v1/file/cancel", "/v1/ping"])
    @MainActor
    func v1EnvelopeGetsUpgradeRequired(path: String) async throws {
        let harness = try ClipServerHarness(requestDeadline: 5)
        defer { harness.server.stop() }
        let port = try await harness.start()

        let body = Data(#"{"v":1,"sourceDeviceId":"11111111-1111-1111-1111-111111111111","nonce":"AAAAAAAAAAAAAAAB","ciphertext":"AAAAAAAAAAAAAAAAAAAAAA=="}"#.utf8)
        let request = HTTPRequest(method: "POST", path: path, headers: ["Content-Type": "application/json"], body: body)
        let outcome = await ClipServerHarness.exchange(
            port: port,
            payload: HTTPCodec.encodeRequest(request, host: "127.0.0.1:\(port.rawValue)"),
            timeout: 3
        )
        let response = try HTTPCodec.parseResponse(outcome.received)
        #expect(response.statusCode == 426)
        let obj = try #require(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        #expect(obj["status"] as? String == "upgradeRequired")
        #expect(obj["minVersion"] as? Int == 2)
    }
}

@Suite("ClipServer replay protection")
@MainActor
struct ClipServerReplayTests {
    private struct Setup {
        let server: ClipServer
        let pasteboard: CountingPasteboard
        let localId: UUID
        let peerId: UUID
        let key: SymmetricKey
    }

    private func makeSetup() async throws -> Setup {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = try ClipStore(storageDirectory: directory)
        let identity = DeviceIdentity(id: UUID(), name: "Test Mac")
        let pairedStore = try PairedDeviceStore(
            storageURL: directory.appendingPathComponent("paired-devices.json"),
            keyStorage: MemoryPairKeyStorage()
        )
        let peerId = UUID()
        let key = SymmetricKey(size: .bits256)
        try await pairedStore.addDevice(PairedDevice(id: peerId, name: "Phone"), key: key)
        let coordinator = PairingCoordinator(identity: identity, pairedStore: pairedStore, transport: HarnessPeerTransport())
        let pasteboard = CountingPasteboard()
        let server = try ClipServer(
            identity: identity,
            receiver: ClipReceiver(store: store, pasteboard: pasteboard),
            pairingCoordinator: coordinator,
            port: .any,
            advertisesService: false
        )
        return Setup(server: server, pasteboard: pasteboard, localId: identity.id, peerId: peerId, key: key)
    }

    private func clipBody(_ setup: Setup, text: String, sentAt: Date = Date()) throws -> Data {
        let payload = ClipPayload(
            id: UUID(), type: .text, createdAt: Date(), text: text,
            previewText: text, contentHash: ContentHasher.textHash(text), sourceDeviceName: "Phone"
        )
        let envelope = try ClipEnvelope.seal(
            payload: payload, purpose: .clip,
            sourceDeviceId: setup.peerId, recipientDeviceId: setup.localId,
            pairKey: setup.key, sentAt: sentAt
        )
        return try JSONEncoder().encode(envelope)
    }

    private func status(_ response: HTTPResponse) -> String? {
        (try? JSONSerialization.jsonObject(with: response.body) as? [String: Any])?["status"] as? String
    }

    @Test("a replayed clip does not touch the pasteboard")
    func replayedClipDoesNotTouchPasteboard() async throws {
        let setup = try await makeSetup()
        let body = try clipBody(setup, text: "secret")

        #expect(await setup.server.handleClipRequest(body: body).statusCode == 200)
        #expect(setup.pasteboard.writeCount == 1)

        let replayed = await setup.server.handleClipRequest(body: body)
        #expect(replayed.statusCode == 409)
        #expect(status(replayed) == "replayed")
        #expect(setup.pasteboard.writeCount == 1)
    }

    @Test("a clip sent 20 minutes ago is stale and not pasted; 4 minutes ago syncs (Review Focus 1)")
    func staleClipIsRejected() async throws {
        let setup = try await makeSetup()
        let stale = await setup.server.handleClipRequest(body: try clipBody(setup, text: "old", sentAt: Date().addingTimeInterval(-1_200)))
        #expect(stale.statusCode == 400)
        #expect(status(stale) == "stale")
        #expect(setup.pasteboard.writeCount == 0)

        let skewed = await setup.server.handleClipRequest(body: try clipBody(setup, text: "skewed", sentAt: Date().addingTimeInterval(240)))
        #expect(skewed.statusCode == 200)
        #expect(setup.pasteboard.writeCount == 1)
    }
}

private final class MemoryPairKeyStorage: PairKeyStorage, @unchecked Sendable {
    private var keys: [UUID: SymmetricKey] = [:]
    func storeKey(_ key: SymmetricKey, for deviceId: UUID) throws { keys[deviceId] = key }
    func getKey(for deviceId: UUID) throws -> SymmetricKey? { keys[deviceId] }
    func deleteKey(for deviceId: UUID) throws { keys[deviceId] = nil }
}

private final class CountingPasteboard: PasteboardClient {
    private(set) var writeCount = 0
    func currentChangeCount() -> Int { writeCount }
    func readSnapshot() -> ClipboardSnapshot { ClipboardSnapshot(text: nil, imageData: nil) }
    func clearContents() {}
    func writeText(_ text: String) { writeCount += 1 }
    func writeImageData(_ data: Data) { writeCount += 1 }
}

/// Runs a real ClipServer on an ephemeral loopback port without advertising Bonjour.
private final class ClipServerHarness: @unchecked Sendable {
    let server: ClipServer
    let coordinator: PairingCoordinator
    let identity: DeviceIdentity

    @MainActor
    init(requestDeadline: TimeInterval) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = try ClipStore(storageDirectory: directory)
        let identity = DeviceIdentity(id: UUID(), name: "Test Mac")
        self.identity = identity
        let pairedStore = try PairedDeviceStore(
            storageURL: directory.appendingPathComponent("paired-devices.json"),
            keyStorage: HarnessPairKeyStorage()
        )
        let coordinator = PairingCoordinator(identity: identity, pairedStore: pairedStore, transport: HarnessPeerTransport())
        self.coordinator = coordinator
        let fileReceiver = FileReceiver(
            pairedStore: pairedStore,
            localDeviceId: identity.id,
            transfersDirectory: directory.appendingPathComponent("Transfers"),
            destinationProvider: { directory }
        )
        server = try ClipServer(
            identity: identity,
            receiver: ClipReceiver(store: store, pasteboard: HarnessPasteboard()),
            pairingCoordinator: coordinator,
            fileReceiver: fileReceiver,
            port: .any,
            advertisesService: false,
            requestDeadline: requestDeadline
        )
    }

    func start() async throws -> NWEndpoint.Port {
        server.start()
        for _ in 0..<200 {
            if let port = server.boundPort, port.rawValue != 0 { return port }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw URLError(.cannotConnectToHost)
    }

    struct Outcome: Sendable {
        var received = Data()
        var closedByServer = false
        var elapsed: TimeInterval = 0
    }

    /// Connects, optionally sends `payload`, then reads until the server closes or `timeout` passes.
    static func exchange(port: NWEndpoint.Port, payload: Data?, timeout: TimeInterval) async -> Outcome {
        await withCheckedContinuation { continuation in
            final class State: @unchecked Sendable {
                let lock = NSLock()
                var done = false
                var outcome = Outcome()
            }
            let state = State()
            let started = Date()
            let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)

            @Sendable func finish(closed: Bool) {
                state.lock.lock()
                defer { state.lock.unlock() }
                guard !state.done else { return }
                state.done = true
                state.outcome.closedByServer = closed
                state.outcome.elapsed = Date().timeIntervalSince(started)
                connection.cancel()
                continuation.resume(returning: state.outcome)
            }

            @Sendable func receive() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                    if let data {
                        state.lock.lock()
                        state.outcome.received.append(data)
                        state.lock.unlock()
                    }
                    if isComplete || error != nil {
                        finish(closed: true)
                    } else {
                        receive()
                    }
                }
            }

            connection.stateUpdateHandler = { newState in
                switch newState {
                case .ready:
                    if let payload {
                        connection.send(content: payload, completion: .contentProcessed { _ in })
                    }
                    receive()
                case .failed:
                    finish(closed: true)
                default:
                    break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                finish(closed: false)
            }
        }
    }
}

private final class HarnessPairKeyStorage: PairKeyStorage, @unchecked Sendable {
    func storeKey(_ key: SymmetricKey, for deviceId: UUID) throws {}
    func getKey(for deviceId: UUID) throws -> SymmetricKey? { nil }
    func deleteKey(for deviceId: UUID) throws {}
}

private struct HarnessPeerTransport: PeerTransport {
    func send(_ data: Data, to peer: Peer) async throws -> Data { Data() }
}

private final class HarnessPasteboard: PasteboardClient {
    func currentChangeCount() -> Int { 0 }
    func readSnapshot() -> ClipboardSnapshot { ClipboardSnapshot(text: nil, imageData: nil) }
    func clearContents() {}
    func writeText(_ text: String) {}
    func writeImageData(_ data: Data) {}
}
