import Foundation
import CryptoKit

public enum PairingError: Error {
    case invalidPublicKey
    case invalidConfirmationProof
    case missingSharedSecret
    case notHosting
}

public struct PairingSession: Sendable {
    private let privateKey: Curve25519.KeyAgreement.PrivateKey
    public let ephemeralPublicKey: Data

    public init() {
        self.privateKey = Curve25519.KeyAgreement.PrivateKey()
        self.ephemeralPublicKey = privateKey.publicKey.rawRepresentation
    }

    public func completePairing(
        remotePublicKey: Data,
        initiatorId: UUID,
        targetId: UUID,
        isInitiator: Bool,
        code: String
    ) throws -> (pairKey: SymmetricKey, confirmCode: String) {
        guard let remoteKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: remotePublicKey) else {
            throw PairingError.invalidPublicKey
        }

        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: remoteKey)
        let info = Data(code.utf8)

        let pairKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: "ClipboardSS_PairKey".data(using: .utf8)!,
            sharedInfo: info,
            outputByteCount: 32
        )

        let codeKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: "ClipboardSS_ConfirmCode".data(using: .utf8)!,
            sharedInfo: info,
            outputByteCount: 4
        )
        
        let codeValue = codeKey.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        let confirmCode = String(format: "%06d", (codeValue % 1_000_000))
        
        return (pairKey, confirmCode)
    }

    public static func generateConfirmationProof(
        pairKey: SymmetricKey,
        initiatorId: UUID,
        targetId: UUID
    ) -> Data {
        let message = confirmationMessage(initiatorId: initiatorId, targetId: targetId).data(using: .utf8)!
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: pairKey)
        return Data(mac)
    }

    public static func confirmationMessage(initiatorId: UUID, targetId: UUID) -> String {
        "confirm\(initiatorId.uuidString.lowercased())\(targetId.uuidString.lowercased())"
    }

    public static func verifyConfirmationProof(
        proof: Data,
        pairKey: SymmetricKey,
        initiatorId: UUID,
        targetId: UUID
    ) -> Bool {
        let expectedProof = generateConfirmationProof(pairKey: pairKey, initiatorId: initiatorId, targetId: targetId)
        return proof == expectedProof
    }
}
