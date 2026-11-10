import Foundation
import CryptoKit
import ClipboardCore

/// Result of a `/v1/pair/confirm` request on the hosting (target) side.
public enum PairConfirmOutcome: Equatable, Sendable {
    case paired
    case rejected
    case alreadyPaired
}

@MainActor
public final class PairingCoordinator: ObservableObject {
    public let identity: DeviceIdentity
    public let pairedStore: PairedDeviceStore
    private let transport: PeerTransport
    
    /// The single initiator that has completed `/v1/pair/start` against the hosted code.
    private struct PendingInitiator {
        let id: UUID
        let name: String
        let host: String
        let pairKey: SymmetricKey
    }

    // Hosting state. All pairing rules on the target side are enforced in
    // `handlePairStartRequest` / `handlePairConfirmRequest` below:
    // one pending initiator per code, confirm only while the code is active,
    // any confirm ends the code, and no silent re-pair of a known deviceId.
    private var pending: PendingInitiator?

    @Published public var hostCode: String?
    @Published public var isPairing: Bool = false
    private var hostCodeExpiry: Date?
    private let now: () -> Date

    /// Invoked on the main actor whenever a device is successfully added to the
    /// paired store, so observers can refresh their view of paired devices.
    public var onPairedDevicesChanged: (() -> Void)?
    
    public init(
        identity: DeviceIdentity,
        pairedStore: PairedDeviceStore,
        transport: PeerTransport,
        now: @escaping () -> Date = Date.init
    ) {
        self.identity = identity
        self.pairedStore = pairedStore
        self.transport = transport
        self.now = now
    }

    public func startHosting(ttl: TimeInterval = 180) -> String {
        let code = String(format: "%06d", Int.random(in: 0...999_999))
        pending = nil
        hostCode = code
        hostCodeExpiry = now().addingTimeInterval(ttl)
        return code
    }

    public func stopHosting() {
        pending = nil
        hostCode = nil
        hostCodeExpiry = nil
    }

    /// The hosted code while it is unexpired; an expired code is cleared together with any pending initiator.
    private func activeHostCode() -> String? {
        guard let code = hostCode, let expiry = hostCodeExpiry, expiry > now() else {
            stopHosting()
            return nil
        }
        return code
    }
    
    public func handlePairStartRequest(
        initiatorId: UUID,
        initiatorName: String,
        initiatorPubKeyBase64: String,
        remoteHost: String
    ) async throws -> Data {
        logToFile("PairingCoordinator: handlePairStartRequest from \(initiatorName) (\(initiatorId.uuidString))")
        guard let code = activeHostCode() else {
            logToFile("PairingCoordinator: Rejecting pair start because this device is not hosting")
            throw PairingError.notHosting
        }
        if let pending, pending.id != initiatorId {
            logToFile("PairingCoordinator: Rejecting pair start because another initiator is pending")
            throw PairingError.initiatorConflict
        }
        guard let initiatorPubKey = Data(base64Encoded: initiatorPubKeyBase64) else {
            logToFile("PairingCoordinator: Invalid public key base64")
            throw PairingError.invalidPublicKey
        }

        let session = PairingSession()
        let (pairKey, _) = try session.completePairing(
            remotePublicKey: initiatorPubKey,
            initiatorId: initiatorId,
            targetId: identity.id,
            isInitiator: false,
            code: code
        )

        pending = PendingInitiator(id: initiatorId, name: initiatorName, host: remoteHost, pairKey: pairKey)
        logToFile("PairingCoordinator: Ephemeral key complete for hosted code")
        return session.ephemeralPublicKey
    }
    
    public func handlePairConfirmRequest(initiatorId: UUID, proofBase64: String) async throws -> PairConfirmOutcome {
        logToFile("PairingCoordinator: handlePairConfirmRequest from \(initiatorId.uuidString)")
        // Every confirm ends the hosted code, whatever its outcome. Taking the pending
        // initiator before any suspension point also keeps concurrent confirms from racing.
        let codeIsActive = activeHostCode() != nil
        let pending = self.pending
        stopHosting()

        guard codeIsActive,
              let pending, pending.id == initiatorId,
              let proof = Data(base64Encoded: proofBase64),
              PairingSession.verifyConfirmationProof(proof: proof, pairKey: pending.pairKey, initiatorId: initiatorId, targetId: identity.id)
        else {
            logToFile("PairingCoordinator: Rejecting pair confirm; the code is now invalid")
            return .rejected
        }

        if await pairedStore.devices.contains(where: { $0.id == initiatorId }) {
            logToFile("PairingCoordinator: Rejecting pair confirm for an already paired device")
            return .alreadyPaired
        }

        try await pairedStore.addDevice(
            PairedDevice(id: initiatorId, name: pending.name, host: pending.host),
            key: pending.pairKey
        )
        logToFile("PairingCoordinator: Device paired successfully and saved!")
        onPairedDevicesChanged?()
        return .paired
    }
    
    public func startPairing(with peer: Peer, code: String) async throws {
        logToFile("PairingCoordinator: startPairing initiated with peer \(peer.name) (\(peer.id.uuidString)) host=\(peer.host) port=\(peer.port)")
        isPairing = true
        defer { isPairing = false }
        
        let session = PairingSession()
        
        struct PairStartReq: Codable {
            let deviceId: UUID
            let deviceName: String
            let ephemeralPublicKey: String
        }
        let req = PairStartReq(deviceId: identity.id, deviceName: identity.name, ephemeralPublicKey: session.ephemeralPublicKey.base64EncodedString())
        let reqData = try JSONEncoder().encode(req)
        
        let request = HTTPRequest(method: "POST", path: "/v1/pair/start", headers: ["Content-Type": "application/json"], body: reqData)
        let requestBytes = HTTPCodec.encodeRequest(request, host: "\(peer.host)")
        
        logToFile("PairingCoordinator: Sending /v1/pair/start to \(peer.host)...")
        let responseData: Data
        do {
            responseData = try await transport.send(requestBytes, to: peer)
            logToFile("PairingCoordinator: Received /v1/pair/start response (\(responseData.count) bytes)")
        } catch {
            logToFile("PairingCoordinator: /v1/pair/start failed with transport error: \(error)")
            throw error
        }
        
        let response = try HTTPCodec.parseResponse(responseData)
        logToFile("PairingCoordinator: /v1/pair/start HTTP Status: \(response.statusCode)")
        
        if response.statusCode != 200 {
            logToFile("PairingCoordinator: /v1/pair/start returned bad status: \(response.statusCode)")
            throw URLError(.badServerResponse)
        }
        
        struct PairStartResp: Codable {
            let deviceId: UUID
            let deviceName: String
            let ephemeralPublicKey: String
        }
        let targetResp = try JSONDecoder().decode(PairStartResp.self, from: response.body)
        logToFile("PairingCoordinator: Decoded PairStartResp, targetDeviceId=\(targetResp.deviceId), targetDeviceName=\(targetResp.deviceName)")
        
        guard let targetPubKey = Data(base64Encoded: targetResp.ephemeralPublicKey) else {
            logToFile("PairingCoordinator: Target returned invalid public key")
            throw PairingError.invalidPublicKey
        }
        
        let (pairKey, _) = try session.completePairing(
            remotePublicKey: targetPubKey,
            initiatorId: identity.id,
            targetId: targetResp.deviceId,
            isInitiator: true,
            code: code
        )
        logToFile("PairingCoordinator: Completed ephemeral key exchange")
        
        let proof = PairingSession.generateConfirmationProof(pairKey: pairKey, initiatorId: identity.id, targetId: targetResp.deviceId)
        
        struct PairConfirmReq: Codable {
            let deviceId: UUID
            let proof: String
        }
        let confirmReq = PairConfirmReq(deviceId: identity.id, proof: proof.base64EncodedString())
        let confirmReqData = try JSONEncoder().encode(confirmReq)
        
        let confirmRequest = HTTPRequest(method: "POST", path: "/v1/pair/confirm", headers: ["Content-Type": "application/json"], body: confirmReqData)
        let confirmRequestBytes = HTTPCodec.encodeRequest(confirmRequest, host: "\(peer.host)")
        
        logToFile("PairingCoordinator: Sending /v1/pair/confirm...")
        let confirmResponseData: Data
        do {
            confirmResponseData = try await transport.send(confirmRequestBytes, to: peer)
            logToFile("PairingCoordinator: Received /v1/pair/confirm response (\(confirmResponseData.count) bytes)")
        } catch {
            logToFile("PairingCoordinator: /v1/pair/confirm failed with transport error: \(error)")
            throw error
        }
        
        let confirmResponse = try HTTPCodec.parseResponse(confirmResponseData)
        logToFile("PairingCoordinator: /v1/pair/confirm HTTP Status: \(confirmResponse.statusCode)")
        
        if confirmResponse.statusCode == 200 {
            logToFile("PairingCoordinator: Pairing SUCCESSFUL! Saving peer to PairedStore.")
            try await pairedStore.addDevice(
                PairedDevice(id: targetResp.deviceId, name: targetResp.deviceName, host: peer.host),
                key: pairKey
            )
            onPairedDevicesChanged?()
        } else if confirmResponse.statusCode == 409 {
            logToFile("PairingCoordinator: Target already has this device paired")
            throw PairingError.alreadyPaired
        } else {
            logToFile("PairingCoordinator: Confirm returned status \(confirmResponse.statusCode), user denied pairing?")
            throw URLError(.userAuthenticationRequired)
        }
    }
}
