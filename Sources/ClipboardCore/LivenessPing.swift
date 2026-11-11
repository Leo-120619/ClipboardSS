import Foundation
import CryptoKit

/// What one `POST /v1/ping` to one host proved. See docs/wire-protocol.md ("Liveness Ping").
public enum PingOutcome: Sendable, Equatable {
    /// A valid pong from the expected device: it is online at the pinged host and speaks v2.
    case alive
    /// The host answered 426 (or 404, a v1 server without the ping route): it speaks
    /// another protocol version.
    case upgradeRequired
    /// The host answered `400 {"status":"stale"}`: its clock disagrees with ours by more
    /// than the freshness window. Unauthenticated, so it never proves liveness.
    case clockSkew
    /// No evidence either way: unreachable, or an answer that is not a valid, fresh pong
    /// from the expected device for this ping.
    case unverified
}

/// Inner payload of a `ping` envelope: only the `sentAt` the seal helpers stamp.
struct PingPayload: Codable {}

/// Inner payload of a `pong` envelope: echoes the ping's nonce so a captured pong
/// cannot answer a later ping.
struct PongPayload: Codable {
    let pingNonce: String
}

/// Authenticated liveness: the only evidence that a paired device is online at a host.
public enum LivenessPing {
    public static let path = "/v1/ping"

    /// Pings `deviceId` at `host` and validates the pong. `send` delivers the encoded HTTP
    /// request to that host and returns the raw response.
    public static func ping(
        host: String,
        port: UInt16 = 51888,
        deviceId: UUID,
        localDeviceId: UUID,
        pairKey: SymmetricKey,
        now: Date = Date(),
        send: (Data) async throws -> Data
    ) async -> PingOutcome {
        guard
            let envelope = try? ClipEnvelope.seal(
                payload: PingPayload(),
                purpose: .ping,
                sourceDeviceId: localDeviceId,
                recipientDeviceId: deviceId,
                pairKey: pairKey,
                sentAt: now
            ),
            let body = try? JSONEncoder().encode(envelope)
        else { return .unverified }
        let request = HTTPRequest(method: "POST", path: path, headers: ["Content-Type": "application/json"], body: body)
        guard
            let data = try? await send(HTTPCodec.encodeRequest(request, host: "\(host):\(port)")),
            let response = try? HTTPCodec.parseResponse(data)
        else { return .unverified }
        return evaluatePong(
            statusCode: response.statusCode,
            body: response.body,
            pingNonce: envelope.nonce,
            deviceId: deviceId,
            localDeviceId: localDeviceId,
            pairKey: pairKey,
            now: now
        )
    }

    /// Caller-side validation: 200, a v2 `pong` envelope from `deviceId` sealed to us,
    /// fresh within the replay window, echoing this ping's nonce.
    public static func evaluatePong(
        statusCode: Int,
        body: Data,
        pingNonce: String,
        deviceId: UUID,
        localDeviceId: UUID,
        pairKey: SymmetricKey,
        now: Date = Date()
    ) -> PingOutcome {
        // 404: a v1 server has no ping route, so it is an older protocol, not "offline".
        if statusCode == 426 || statusCode == 404 { return .upgradeRequired }
        if statusCode == 400, ProtocolMismatch.responseStatus(body) == "stale" { return .clockSkew }
        guard
            statusCode == 200,
            let envelope = try? JSONDecoder().decode(ClipEnvelope.self, from: body),
            envelope.sourceDeviceId == deviceId,
            let opened = try? envelope.openStamped(
                PongPayload.self,
                purpose: .pong,
                recipientDeviceId: localDeviceId,
                pairKey: pairKey
            ),
            abs(now.timeIntervalSince(opened.sentAt)) <= ReplayGuard.defaultWindow,
            let echoed = Data(base64Encoded: opened.payload.pingNonce),
            let sent = Data(base64Encoded: pingNonce),
            echoed == sent
        else { return .unverified }
        return .alive
    }

    /// Responder side of `POST /v1/ping`: version → pairing → AEAD open → replay guard →
    /// pong sealed back to the caller. The local pause switch is not consulted: liveness
    /// reports reachability, and pausing only refuses content.
    public static func respond(
        body: Data,
        localDeviceId: UUID,
        pairedStore: PairedDeviceStore,
        replayGuard: ReplayGuard
    ) async -> FileTransferResponse {
        guard let envelope = try? JSONDecoder().decode(ClipEnvelope.self, from: body) else {
            return .status(400)
        }
        guard envelope.v == ClipEnvelope.currentVersion else { return .upgradeRequired }
        guard let key = try? await pairedStore.getKey(for: envelope.sourceDeviceId) else {
            return .status(401)
        }
        guard let opened = try? envelope.openStamped(
            PingPayload.self,
            purpose: .ping,
            recipientDeviceId: localDeviceId,
            pairKey: key
        ) else {
            return .status(401)
        }
        let check = await replayGuard.check(sourceDeviceId: envelope.sourceDeviceId, nonce: envelope.nonce, sentAt: opened.sentAt)
        if let rejection = FileTransferResponse.rejection(for: check) { return rejection }
        guard
            let pong = try? ClipEnvelope.seal(
                payload: PongPayload(pingNonce: envelope.nonce),
                purpose: .pong,
                sourceDeviceId: localDeviceId,
                recipientDeviceId: envelope.sourceDeviceId,
                pairKey: key
            ),
            let pongBody = try? JSONEncoder().encode(pong)
        else { return .status(500) }
        return FileTransferResponse(statusCode: 200, body: pongBody)
    }
}
