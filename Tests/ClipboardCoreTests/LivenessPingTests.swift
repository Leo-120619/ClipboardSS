import Foundation
import CryptoKit
import Testing
@testable import ClipboardCore

@Suite("Liveness ping")
struct LivenessPingTests {
    private let local = UUID()
    private let device = UUID()
    private let key = SymmetricKey(size: .bits256)

    /// A responder for `device` that knows `local` under `key`, answering over an in-memory "wire".
    private func responder(guard replayGuard: ReplayGuard = ReplayGuard()) async throws -> @Sendable (Data) async throws -> Data {
        let store = try await makePairedStore(peerId: local, key: key)
        let deviceId = device
        return { requestData in
            let request = try HTTPCodec.parseRequest(requestData)
            #expect(request.method == "POST")
            #expect(request.path == LivenessPing.path)
            let result = await LivenessPing.respond(
                body: request.body,
                localDeviceId: deviceId,
                pairedStore: store,
                replayGuard: replayGuard
            )
            return HTTPCodec.encodeResponse(HTTPResponse(statusCode: result.statusCode, headers: [:], body: result.body))
        }
    }

    private func ping(expecting deviceId: UUID? = nil, key pingKey: SymmetricKey? = nil, now: Date = Date(),
                      send: (Data) async throws -> Data) async -> PingOutcome {
        await LivenessPing.ping(
            host: "10.0.0.9",
            deviceId: deviceId ?? device,
            localDeviceId: local,
            pairKey: pingKey ?? key,
            now: now,
            send: send
        )
    }

    @Test("ping and pong purposes appear in the associated data")
    func purposesInAssociatedData() {
        let source = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let recipient = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        #expect(String(decoding: ClipEnvelope.associatedData(purpose: .ping, sourceDeviceId: source, recipientDeviceId: recipient), as: UTF8.self)
            == "ClipboardSS/2|ping|11111111-1111-1111-1111-111111111111|22222222-2222-2222-2222-222222222222")
        #expect(String(decoding: ClipEnvelope.associatedData(purpose: .pong, sourceDeviceId: source, recipientDeviceId: recipient), as: UTF8.self)
            == "ClipboardSS/2|pong|11111111-1111-1111-1111-111111111111|22222222-2222-2222-2222-222222222222")
    }

    @Test("ping and pong envelopes match the pinned vectors")
    func pinnedVectors() throws {
        let pairKey = SymmetricKey(data: Data((0..<32).map { UInt8($0) }))
        let source = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let recipient = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let nonce = try ChaChaPoly.Nonce(data: Data([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]))
        for (purpose, expected) in [
            (EnvelopePurpose.ping, "127e1dfb0b3bc52649f874034b63d5fa53c0a4886a60a1"),
            (EnvelopePurpose.pong, "127e1dfb0b3bc535d219b680a4ddb08aac15ee49a426c4"),
        ] {
            let envelope = try ClipEnvelope.sealPlaintext(
                Data(#"{"a":1}"#.utf8), purpose: purpose, sourceDeviceId: source,
                recipientDeviceId: recipient, pairKey: pairKey, nonce: nonce
            )
            let bytes = try #require(Data(base64Encoded: envelope.ciphertext))
            #expect(bytes.map { String(format: "%02x", $0) }.joined() == expected)
        }
    }

    @Test("a valid pong from the paired device proves it alive")
    func validPongIsAlive() async throws {
        let send = try await responder()
        #expect(await ping(send: send) == .alive)
    }

    @Test("an impostor answering for the device id without its key is not alive")
    func impostorIsUnverified() async throws {
        // The impostor knows the public device id, but not the pair key.
        let impostorKey = SymmetricKey(size: .bits256)
        let store = try await makePairedStore(peerId: local, key: impostorKey)
        let deviceId = device
        let outcome = await ping { data in
            let request = try HTTPCodec.parseRequest(data)
            let result = await LivenessPing.respond(body: request.body, localDeviceId: deviceId, pairedStore: store, replayGuard: ReplayGuard())
            return HTTPCodec.encodeResponse(HTTPResponse(statusCode: result.statusCode, headers: [:], body: result.body))
        }
        #expect(outcome == .unverified)
    }

    @Test("a 200 that is not a pong, or a 426, is not alive")
    func nonPongResponses() {
        let body = Data(#"{"deviceId":"x","v":2}"#.utf8)
        #expect(LivenessPing.evaluatePong(statusCode: 200, body: body, pingNonce: "AAAAAAAAAAAAAAAB",
                                          deviceId: device, localDeviceId: local, pairKey: key) == .unverified)
        #expect(LivenessPing.evaluatePong(statusCode: 426, body: Data(), pingNonce: "AAAAAAAAAAAAAAAB",
                                          deviceId: device, localDeviceId: local, pairKey: key) == .upgradeRequired)
        #expect(LivenessPing.evaluatePong(statusCode: 401, body: Data(), pingNonce: "AAAAAAAAAAAAAAAB",
                                          deviceId: device, localDeviceId: local, pairKey: key) == .unverified)
    }

    @Test("a pong captured for an earlier ping does not answer a new one")
    func replayedPongIsUnverified() async throws {
        let send = try await responder()
        let captured = Captured()
        #expect(await ping { data in
            let response = try await send(data)
            await captured.set(response)
            return response
        } == .alive)
        let old = try #require(await captured.value)
        #expect(await ping { _ in old } == .unverified)
    }

    @Test("a pong from another paired device, or a stale pong, is not alive")
    func wrongSourceOrStalePong() throws {
        let nonce = Data((0..<12).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let other = UUID()
        let fromOther = try JSONEncoder().encode(ClipEnvelope.seal(
            payload: PongPayload(pingNonce: nonce), purpose: .pong, sourceDeviceId: other, recipientDeviceId: local, pairKey: key))
        #expect(LivenessPing.evaluatePong(statusCode: 200, body: fromOther, pingNonce: nonce,
                                          deviceId: device, localDeviceId: local, pairKey: key) == .unverified)

        let stale = try JSONEncoder().encode(ClipEnvelope.seal(
            payload: PongPayload(pingNonce: nonce), purpose: .pong, sourceDeviceId: device, recipientDeviceId: local,
            pairKey: key, sentAt: Date().addingTimeInterval(-301)))
        #expect(LivenessPing.evaluatePong(statusCode: 200, body: stale, pingNonce: nonce,
                                          deviceId: device, localDeviceId: local, pairKey: key) == .unverified)

        let fresh = try JSONEncoder().encode(ClipEnvelope.seal(
            payload: PongPayload(pingNonce: nonce), purpose: .pong, sourceDeviceId: device, recipientDeviceId: local,
            pairKey: key, sentAt: Date().addingTimeInterval(-240)))
        #expect(LivenessPing.evaluatePong(statusCode: 200, body: fresh, pingNonce: nonce,
                                          deviceId: device, localDeviceId: local, pairKey: key) == .alive)
    }

    @Test("the responder answers 426, 401, 400 stale and 409 replayed")
    func responderRejections() async throws {
        let store = try await makePairedStore(peerId: local, key: key)
        let replayGuard = ReplayGuard()
        func respond(_ envelope: ClipEnvelope) async throws -> Int {
            await LivenessPing.respond(body: try JSONEncoder().encode(envelope), localDeviceId: device,
                                       pairedStore: store, replayGuard: replayGuard).statusCode
        }
        let ping = try ClipEnvelope.seal(payload: PingPayload(), purpose: .ping, sourceDeviceId: local, recipientDeviceId: device, pairKey: key)

        let v1 = ClipEnvelope(v: 1, sourceDeviceId: local, nonce: ping.nonce, ciphertext: ping.ciphertext)
        #expect(try await respond(v1) == 426)
        let unpaired = try ClipEnvelope.seal(payload: PingPayload(), purpose: .ping, sourceDeviceId: UUID(), recipientDeviceId: device, pairKey: key)
        #expect(try await respond(unpaired) == 401)
        let clipPurpose = try ClipEnvelope.seal(payload: PingPayload(), purpose: .clip, sourceDeviceId: local, recipientDeviceId: device, pairKey: key)
        #expect(try await respond(clipPurpose) == 401)
        let stale = try ClipEnvelope.seal(payload: PingPayload(), purpose: .ping, sourceDeviceId: local, recipientDeviceId: device,
                                          pairKey: key, sentAt: Date().addingTimeInterval(-301))
        #expect(try await respond(stale) == 400)
        #expect(try await respond(ping) == 200)
        #expect(try await respond(ping) == 409)
    }
}

private actor Captured {
    var value: Data?
    func set(_ data: Data) { value = data }
}
