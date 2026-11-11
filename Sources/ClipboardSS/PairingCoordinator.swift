import Foundation
import CryptoKit
import ClipboardCore

/// Result of a `/v1/pair/reveal` request on the hosting (target) side.
public enum PairRevealOutcome: Equatable, Sendable {
    /// 200: the commitment opened; both screens now show the number.
    case ok
    /// 401: no active code, or no matching initiator waiting to reveal.
    case rejected
    /// 400: the revealed key or salt does not open the commitment.
    case invalid
}

/// Result of a `/v1/pair/confirm` request on the hosting (target) side.
public enum PairConfirmOutcome: Equatable, Sendable {
    case paired
    case rejected
    case alreadyPaired
    /// 408: this device's user did not confirm the number in time.
    case timedOut
}

/// The number both screens show during pairing, with the other device's name.
public struct PairingComparison: Equatable, Sendable {
    /// The other device.
    public let deviceName: String
    public let confirmCode: String
    /// This device's user already pressed Confirm and is waiting for the other side.
    public var localConfirmed: Bool
}

@MainActor
public final class PairingCoordinator: ObservableObject {
    /// How long the target holds `/v1/pair/confirm` waiting for its own user (else 408).
    public static let confirmHoldTimeout: TimeInterval = 60
    /// Client timeout for `/v1/pair/confirm`: longer than the target's hold.
    public static let confirmRequestTimeout: TimeInterval = 75

    public let identity: DeviceIdentity
    public let pairedStore: PairedDeviceStore
    private let transport: PeerTransport
    private let confirmHoldTimeout: TimeInterval

    /// The single initiator that has sent `/v1/pair/start` against the hosted code.
    private struct PendingInitiator {
        let id: UUID
        let name: String
        let host: String
        let commitment: Data
        let session: PairingSession
        /// Set by a valid `/v1/pair/reveal`.
        var pairKey: SymmetricKey?
    }

    /// A valid `/v1/pair/confirm` waiting for this device's user.
    private struct HeldConfirm {
        let initiatorId: UUID
        let continuation: CheckedContinuation<HostDecision, Never>
        let timeout: Task<Void, Never>
    }

    private enum HostDecision { case confirmed, cancelled, timedOut }

    // Hosting state. All pairing rules on the target side are enforced in
    // `handlePairStartRequest` / `handlePairRevealRequest` / `handlePairConfirmRequest`:
    // - a code hands out at most one target key: any second start (same deviceId
    //   or not) ends the code with 403;
    // - reveal and confirm are refused (401) unless the code is active and unexpired;
    // - any failure (bad reveal or commitment, bad proof, cancel here, 60 s confirm
    //   timeout) ends the code and clears pending state; so do stop, expiry and start;
    // - every confirm spends the code; an already paired deviceId gets 409;
    // - keys are stored only after both users confirmed the number;
    // - commitment and proof checks are constant-time; codes, numbers and keys are never logged.
    private var pending: PendingInitiator?
    private var held: HeldConfirm?
    private var hostCodeExpiry: Date?
    /// Bumped whenever hosting ends, so a handler resumed after an await can tell
    /// whether the state it read is still current.
    private var generation = 0
    private var expiryTask: Task<Void, Never>?
    private let now: () -> Date

    @Published public private(set) var hostCode: String?
    /// The number to compare while this device is the target.
    @Published public private(set) var hostComparison: PairingComparison?
    @Published public var isPairing: Bool = false

    // Initiator state: the one device the user chose, waiting for the user to compare numbers.
    private struct PendingJoin {
        let id = UUID()
        let peer: Peer
        let targetId: UUID
        let targetName: String
        let pairKey: SymmetricKey
    }
    private var pendingJoin: PendingJoin?
    /// The number to compare while this device is the initiator.
    @Published public private(set) var joinComparison: PairingComparison?

    /// Invoked on the main actor whenever a device is successfully added to the
    /// paired store, so observers can refresh their view of paired devices.
    public var onPairedDevicesChanged: (() -> Void)?

    public init(
        identity: DeviceIdentity,
        pairedStore: PairedDeviceStore,
        transport: PeerTransport,
        confirmHoldTimeout: TimeInterval = PairingCoordinator.confirmHoldTimeout,
        now: @escaping () -> Date = Date.init
    ) {
        self.identity = identity
        self.pairedStore = pairedStore
        self.transport = transport
        self.confirmHoldTimeout = confirmHoldTimeout
        self.now = now
    }

    /// True while a `/v1/pair/confirm` is waiting for this device's user.
    var isHoldingConfirm: Bool { held != nil }

    // MARK: - Target

    public func startHosting(ttl: TimeInterval = 180) -> String {
        endHosting()
        let code = String(format: "%06d", Int.random(in: 0...999_999))
        hostCode = code
        hostCodeExpiry = now().addingTimeInterval(ttl)
        // Clears the code from the UI when it expires, without waiting for a request.
        expiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(ttl, 0) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            _ = self?.activeHostCode()
        }
        return code
    }

    public func stopHosting() {
        endHosting()
    }

    /// This device's user confirmed the number shown in `hostComparison`.
    public func confirmHostedPairing() {
        if let held {
            resolveHeld(held, with: .confirmed)
        } else if hostComparison != nil {
            hostComparison?.localConfirmed = true
        }
    }

    /// This device's user cancelled (or the numbers differ): the code is spent.
    public func cancelHostedPairing() {
        endHosting()
    }

    /// Ends the hosted code and all pending state; a held confirm is answered 401.
    private func endHosting() {
        generation += 1
        pending = nil
        hostCode = nil
        hostCodeExpiry = nil
        expiryTask?.cancel()
        expiryTask = nil
        hostComparison = nil
        if let held { resolveHeld(held, with: .cancelled) }
    }

    private func endHostingIfCurrent(_ generation: Int) {
        guard generation == self.generation else { return }
        endHosting()
    }

    private func resolveHeld(_ held: HeldConfirm, with decision: HostDecision) {
        self.held = nil
        held.timeout.cancel()
        held.continuation.resume(returning: decision)
    }

    /// The hosted code while it is unexpired; an expired code ends hosting.
    private func activeHostCode() -> String? {
        guard let code = hostCode else { return nil }
        guard let expiry = hostCodeExpiry, expiry > now() else {
            endHosting()
            return nil
        }
        return code
    }

    public func handlePairStartRequest(
        initiatorId: UUID,
        initiatorName: String,
        commitmentBase64: String,
        remoteHost: String
    ) async throws -> Data {
        logToFile("PairingCoordinator: handlePairStartRequest from \(initiatorName) (\(initiatorId.uuidString))")
        guard activeHostCode() != nil else {
            logToFile("PairingCoordinator: Rejecting pair start because this device is not hosting")
            throw PairingError.notHosting
        }
        if pending != nil {
            // This code already handed out a key; a second one would let a code holder
            // re-roll the comparison number. The user must generate a new code.
            logToFile("PairingCoordinator: Second pair start for this code; the code is now invalid")
            endHosting()
            throw PairingError.initiatorConflict
        }
        guard let commitment = Data(base64Encoded: commitmentBase64), commitment.count == 32 else {
            logToFile("PairingCoordinator: Rejecting pair start with a malformed commitment")
            throw PairingError.invalidCommitment
        }

        let session = PairingSession()
        pending = PendingInitiator(
            id: initiatorId,
            name: initiatorName,
            host: remoteHost,
            commitment: commitment,
            session: session
        )
        return session.ephemeralPublicKey
    }

    public func handlePairRevealRequest(
        initiatorId: UUID,
        initiatorPubKeyBase64: String,
        saltBase64: String
    ) -> PairRevealOutcome {
        guard let code = activeHostCode() else { return .rejected }
        guard var pending, pending.id == initiatorId, pending.pairKey == nil else {
            logToFile("PairingCoordinator: Rejecting pair reveal; the code is now invalid")
            endHosting()
            return .rejected
        }
        guard let initiatorPublicKey = Data(base64Encoded: initiatorPubKeyBase64),
              let salt = Data(base64Encoded: saltBase64), salt.count == PairingSession.saltLength,
              PairingSession.commitmentMatches(pending.commitment, publicKey: initiatorPublicKey, salt: salt),
              let derived = try? pending.session.completePairing(
                  remotePublicKey: initiatorPublicKey,
                  isInitiator: false,
                  code: code
              )
        else {
            logToFile("PairingCoordinator: Pair reveal does not open the commitment; the code is now invalid")
            endHosting()
            return .invalid
        }

        pending.pairKey = derived.pairKey
        self.pending = pending
        hostComparison = PairingComparison(deviceName: pending.name, confirmCode: derived.confirmCode, localConfirmed: false)
        return .ok
    }

    public func handlePairConfirmRequest(initiatorId: UUID, proofBase64: String) async throws -> PairConfirmOutcome {
        logToFile("PairingCoordinator: handlePairConfirmRequest from \(initiatorId.uuidString)")
        guard activeHostCode() != nil else {
            // The initiator that is being held cancelled (it sends a confirm with a bad proof).
            if let held, held.initiatorId == initiatorId {
                logToFile("PairingCoordinator: The other device cancelled pairing")
                endHosting()
            }
            return .rejected
        }
        // Every confirm spends the code. The comparison stays on screen until it is resolved.
        let pending = self.pending
        let localConfirmed = hostComparison?.localConfirmed == true
        self.pending = nil
        hostCode = nil
        hostCodeExpiry = nil
        expiryTask?.cancel()
        let generation = self.generation

        guard let pending, pending.id == initiatorId, let pairKey = pending.pairKey,
              let proof = Data(base64Encoded: proofBase64),
              PairingSession.verifyConfirmationProof(proof: proof, pairKey: pairKey, initiatorId: initiatorId, targetId: identity.id)
        else {
            logToFile("PairingCoordinator: Rejecting pair confirm; the code is now invalid")
            endHosting()
            return .rejected
        }

        if await pairedStore.devices.contains(where: { $0.id == initiatorId }) {
            logToFile("PairingCoordinator: Rejecting pair confirm for an already paired device")
            endHostingIfCurrent(generation)
            return .alreadyPaired
        }
        guard generation == self.generation else { return .rejected }

        if !localConfirmed {
            let decision = await holdForLocalDecision(initiatorId: initiatorId)
            guard decision == .confirmed else {
                logToFile("PairingCoordinator: Pairing was not confirmed on this device")
                endHostingIfCurrent(generation)
                return decision == .timedOut ? .timedOut : .rejected
            }
        }
        guard generation == self.generation else { return .rejected }
        endHosting()

        try await pairedStore.addDevice(
            PairedDevice(id: initiatorId, name: pending.name, host: pending.host),
            key: pairKey
        )
        logToFile("PairingCoordinator: Device paired successfully and saved!")
        onPairedDevicesChanged?()
        return .paired
    }

    private func holdForLocalDecision(initiatorId: UUID) async -> HostDecision {
        // This device's user may have pressed Confirm while the proof was being checked.
        if hostComparison?.localConfirmed == true { return .confirmed }
        let holdNanoseconds = UInt64(max(confirmHoldTimeout, 0) * 1_000_000_000)
        return await withCheckedContinuation { continuation in
            let timeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: holdNanoseconds)
                guard !Task.isCancelled, let self, let held = self.held else { return }
                self.resolveHeld(held, with: .timedOut)
            }
            held = HeldConfirm(initiatorId: initiatorId, continuation: continuation, timeout: timeout)
        }
    }

    /// Answers `/v1/pair/start`, `/v1/pair/reveal` and `/v1/pair/confirm` (plaintext JSON).
    public func respond(toPairRequest request: HTTPRequest, remoteHost: String) async -> HTTPResponse {
        switch request.path {
        case "/v1/pair/start":
            struct PairStartReq: Decodable { let deviceId: UUID; let deviceName: String; let commitment: String }
            struct PairStartResp: Encodable { let deviceId: UUID; let deviceName: String; let ephemeralPublicKey: String }
            do {
                let req = try JSONDecoder().decode(PairStartReq.self, from: request.body)
                let targetPub = try await handlePairStartRequest(
                    initiatorId: req.deviceId,
                    initiatorName: req.deviceName,
                    commitmentBase64: req.commitment,
                    remoteHost: remoteHost
                )
                let body = try JSONEncoder().encode(PairStartResp(
                    deviceId: identity.id,
                    deviceName: identity.name,
                    ephemeralPublicKey: targetPub.base64EncodedString()
                ))
                return Self.json(200, body)
            } catch {
                logToFile("PairingCoordinator: /v1/pair/start rejected/failed: \(error)")
                return HTTPResponse(statusCode: 403, headers: [:], body: Data("Rejected".utf8))
            }
        case "/v1/pair/reveal":
            struct PairRevealReq: Decodable { let deviceId: UUID; let ephemeralPublicKey: String; let salt: String }
            guard let req = try? JSONDecoder().decode(PairRevealReq.self, from: request.body) else {
                return HTTPResponse(statusCode: 400, headers: [:], body: Data("Bad Request".utf8))
            }
            switch handlePairRevealRequest(initiatorId: req.deviceId, initiatorPubKeyBase64: req.ephemeralPublicKey, saltBase64: req.salt) {
            case .ok: return Self.json(200, Data(#"{"status":"ok"}"#.utf8))
            case .rejected: return HTTPResponse(statusCode: 401, headers: [:], body: Data("Unauthorized".utf8))
            case .invalid: return HTTPResponse(statusCode: 400, headers: [:], body: Data("Bad Request".utf8))
            }
        case "/v1/pair/confirm":
            struct PairConfirmReq: Decodable { let deviceId: UUID; let proof: String }
            do {
                let req = try JSONDecoder().decode(PairConfirmReq.self, from: request.body)
                switch try await handlePairConfirmRequest(initiatorId: req.deviceId, proofBase64: req.proof) {
                case .paired: return Self.json(200, Data(#"{"status":"ok"}"#.utf8))
                case .alreadyPaired: return Self.json(409, Data(#"{"status":"alreadyPaired"}"#.utf8))
                case .timedOut: return Self.json(408, Data(#"{"status":"timeout"}"#.utf8))
                case .rejected: return HTTPResponse(statusCode: 401, headers: [:], body: Data("Unauthorized".utf8))
                }
            } catch {
                logToFile("PairingCoordinator: /v1/pair/confirm error: \(error)")
                return HTTPResponse(statusCode: 400, headers: [:], body: Data("Bad Request".utf8))
            }
        default:
            return HTTPResponse(statusCode: 404, headers: [:], body: Data("Not Found".utf8))
        }
    }

    private static func json(_ status: Int, _ body: Data) -> HTTPResponse {
        HTTPResponse(statusCode: status, headers: ["Content-Type": "application/json"], body: body)
    }

    // MARK: - Initiator

    /// Runs `/v1/pair/start` and `/v1/pair/reveal` against the one device the user chose and
    /// returns the number to compare. Nothing is stored until `confirmPairing()` succeeds.
    @discardableResult
    public func startPairing(with peer: Peer, code: String) async throws -> PairingComparison {
        logToFile("PairingCoordinator: startPairing with peer \(peer.name) (\(peer.id.uuidString)) host=\(peer.host) port=\(peer.port)")
        cancelPairing()
        isPairing = true
        defer { isPairing = false }

        let session = PairingSession()
        let salt = PairingSession.randomSalt()

        struct PairStartReq: Encodable { let deviceId: UUID; let deviceName: String; let commitment: String }
        let startResponse = try await post(
            PairStartReq(
                deviceId: identity.id,
                deviceName: identity.name,
                commitment: PairingSession.commitment(publicKey: session.ephemeralPublicKey, salt: salt).base64EncodedString()
            ),
            path: "/v1/pair/start",
            to: peer
        )
        guard startResponse.statusCode == 200 else {
            logToFile("PairingCoordinator: /v1/pair/start returned status \(startResponse.statusCode)")
            throw PairingError.rejected
        }
        struct PairStartResp: Decodable { let deviceId: UUID; let deviceName: String; let ephemeralPublicKey: String }
        let target = try JSONDecoder().decode(PairStartResp.self, from: startResponse.body)
        guard let targetPublicKey = Data(base64Encoded: target.ephemeralPublicKey) else {
            throw PairingError.invalidPublicKey
        }

        struct PairRevealReq: Encodable { let deviceId: UUID; let ephemeralPublicKey: String; let salt: String }
        let revealResponse = try await post(
            PairRevealReq(
                deviceId: identity.id,
                ephemeralPublicKey: session.ephemeralPublicKey.base64EncodedString(),
                salt: salt.base64EncodedString()
            ),
            path: "/v1/pair/reveal",
            to: peer
        )
        guard revealResponse.statusCode == 200 else {
            logToFile("PairingCoordinator: /v1/pair/reveal returned status \(revealResponse.statusCode)")
            throw PairingError.rejected
        }

        let (pairKey, confirmCode) = try session.completePairing(
            remotePublicKey: targetPublicKey,
            isInitiator: true,
            code: code
        )
        pendingJoin = PendingJoin(peer: peer, targetId: target.deviceId, targetName: target.deviceName, pairKey: pairKey)
        let comparison = PairingComparison(deviceName: target.deviceName, confirmCode: confirmCode, localConfirmed: false)
        joinComparison = comparison
        return comparison
    }

    /// This device's user confirmed the number: sends the proof and, once the other
    /// device's user confirmed too (200), stores the pairing.
    public func confirmPairing() async throws {
        guard let join = pendingJoin else { throw PairingError.noPendingPairing }
        joinComparison?.localConfirmed = true
        defer {
            if pendingJoin?.id == join.id {
                pendingJoin = nil
                joinComparison = nil
            }
        }

        let proof = PairingSession.generateConfirmationProof(pairKey: join.pairKey, initiatorId: identity.id, targetId: join.targetId)
        struct PairConfirmReq: Encodable { let deviceId: UUID; let proof: String }
        let response = try await post(
            PairConfirmReq(deviceId: identity.id, proof: proof.base64EncodedString()),
            path: "/v1/pair/confirm",
            to: join.peer,
            timeout: Self.confirmRequestTimeout
        )
        logToFile("PairingCoordinator: /v1/pair/confirm HTTP Status: \(response.statusCode)")

        // The user cancelled while waiting: store nothing, whatever the answer.
        guard pendingJoin?.id == join.id else { throw PairingError.cancelled }

        switch response.statusCode {
        case 200:
            try await pairedStore.addDevice(
                PairedDevice(id: join.targetId, name: join.targetName, host: join.peer.host),
                key: join.pairKey
            )
            onPairedDevicesChanged?()
        case 409: throw PairingError.alreadyPaired
        case 408: throw PairingError.timedOut
        default: throw PairingError.rejected
        }
    }

    /// This device's user cancelled (or the numbers differ). Nothing is stored, even if a
    /// confirm is in flight, and the target is told with a confirm carrying an invalid proof,
    /// which it answers 401 after ending its code and comparison.
    @discardableResult
    public func cancelPairing() -> Task<Void, Never>? {
        joinComparison = nil
        guard let join = pendingJoin else { return nil }
        pendingJoin = nil
        struct PairConfirmReq: Encodable { let deviceId: UUID; let proof: String }
        let notice = PairConfirmReq(deviceId: identity.id, proof: Data(count: 32).base64EncodedString())
        return Task {
            _ = try? await post(notice, path: "/v1/pair/confirm", to: join.peer)
        }
    }

    private func post<Body: Encodable>(
        _ body: Body,
        path: String,
        to peer: Peer,
        timeout: TimeInterval = PeerTransportDefaults.requestTimeout
    ) async throws -> HTTPResponse {
        let request = HTTPRequest(
            method: "POST",
            path: path,
            headers: ["Content-Type": "application/json"],
            body: try JSONEncoder().encode(body)
        )
        let responseData = try await transport.send(HTTPCodec.encodeRequest(request, host: peer.host), to: peer, timeout: timeout)
        return try HTTPCodec.parseResponse(responseData)
    }
}
