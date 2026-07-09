import Foundation
import CryptoKit
import ClipboardCore

@MainActor
public final class PairingCoordinator: ObservableObject {
    public let identity: DeviceIdentity
    public let pairedStore: PairedDeviceStore
    private let transport: PeerTransport
    
    private var pendingTargetSessions: [UUID: PairingSession] = [:]
    private var targetTempKeys: [UUID: SymmetricKey] = [:]
    private var targetDeviceNames: [UUID: String] = [:]
    private var targetHosts: [UUID: String] = [:]
    
    @Published public var hostCode: String?
    @Published public var isPairing: Bool = false
    private var hostCodeExpiry: Date?

    /// Invoked on the main actor whenever a device is successfully added to the
    /// paired store, so observers can refresh their view of paired devices.
    public var onPairedDevicesChanged: (() -> Void)?
    
    public init(identity: DeviceIdentity, pairedStore: PairedDeviceStore, transport: PeerTransport) {
        self.identity = identity
        self.pairedStore = pairedStore
        self.transport = transport
    }

    public func startHosting(ttl: TimeInterval = 180) -> String {
        let code = String(format: "%06d", Int.random(in: 0...999_999))
        hostCode = code
        hostCodeExpiry = Date().addingTimeInterval(ttl)
        return code
    }

    public func stopHosting() {
        hostCode = nil
        hostCodeExpiry = nil
    }

    private func activeHostCode() -> String? {
        guard let code = hostCode, let expiry = hostCodeExpiry, expiry > Date() else {
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
        guard let initiatorPubKey = Data(base64Encoded: initiatorPubKeyBase64) else {
            logToFile("PairingCoordinator: Invalid public key base64")
            throw PairingError.invalidPublicKey
        }

        let session = PairingSession()
        pendingTargetSessions[initiatorId] = session
        targetDeviceNames[initiatorId] = initiatorName
        targetHosts[initiatorId] = remoteHost

        let (pairKey, _) = try session.completePairing(
            remotePublicKey: initiatorPubKey,
            initiatorId: initiatorId,
            targetId: identity.id,
            isInitiator: false,
            code: code
        )

        targetTempKeys[initiatorId] = pairKey
        logToFile("PairingCoordinator: Ephemeral key complete for hosted code")
        return session.ephemeralPublicKey
    }
    
    public func handlePairConfirmRequest(initiatorId: UUID, proofBase64: String) async throws -> Bool {
        logToFile("PairingCoordinator: handlePairConfirmRequest from \(initiatorId.uuidString)")
        guard let proof = Data(base64Encoded: proofBase64),
              let pairKey = targetTempKeys[initiatorId] else {
            logToFile("PairingCoordinator: Missing proof or key for initiator \(initiatorId.uuidString)")
            return false
        }
        
        let isValid = PairingSession.verifyConfirmationProof(proof: proof, pairKey: pairKey, initiatorId: initiatorId, targetId: identity.id)
        logToFile("PairingCoordinator: Verification proof isValid = \(isValid)")
        if isValid {
            try await pairedStore.addDevice(
                PairedDevice(id: initiatorId, name: targetDeviceNames[initiatorId] ?? "Device", host: targetHosts[initiatorId]),
                key: pairKey
            )
            stopHosting()
            self.targetTempKeys[initiatorId] = nil
            self.pendingTargetSessions[initiatorId] = nil
            self.targetDeviceNames[initiatorId] = nil
            self.targetHosts[initiatorId] = nil
            logToFile("PairingCoordinator: Device paired successfully and saved!")
            onPairedDevicesChanged?()
        }
        return isValid
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
        
        let (pairKey, code) = try session.completePairing(
            remotePublicKey: targetPubKey,
            initiatorId: identity.id,
            targetId: targetResp.deviceId,
            isInitiator: true,
            code: code
        )
        logToFile("PairingCoordinator: Completed ephemeral key exchange, pairing code=\(code)")
        
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
        } else {
            logToFile("PairingCoordinator: Confirm returned status \(confirmResponse.statusCode), user denied pairing?")
            throw URLError(.userAuthenticationRequired)
        }
    }
}
