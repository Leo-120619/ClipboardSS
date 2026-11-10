import Foundation
import CryptoKit

public enum PairingError: Error {
    case invalidPublicKey
    case invalidConfirmationProof
    /// `/v1/pair/start` carried a commitment that is not 32 bytes of base64.
    case invalidCommitment
    case missingSharedSecret
    case notHosting
    /// Another initiator is already pending against the hosted code.
    case initiatorConflict
    /// The target already has this device paired; it must be removed there before re-pairing.
    case alreadyPaired
    /// The other device refused: wrong code, number not confirmed there, or cancelled (401).
    case rejected
    /// The other device's user did not confirm the number within 60 s (408).
    case timedOut
    /// There is no pairing waiting for this device's confirmation.
    case noPendingPairing
}

public struct PairingSession: Sendable {
    /// Length of the random salt the initiator commits with (pairing v2).
    public static let saltLength = 16

    private let privateKey: Curve25519.KeyAgreement.PrivateKey
    public let ephemeralPublicKey: Data

    public init() {
        self.privateKey = Curve25519.KeyAgreement.PrivateKey()
        self.ephemeralPublicKey = privateKey.publicKey.rawRepresentation
    }

    /// A session from a fixed X25519 private key; used to reproduce the pinned vector.
    public init(privateKey rawPrivateKey: Data) throws {
        self.privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: rawPrivateKey)
        self.ephemeralPublicKey = privateKey.publicKey.rawRepresentation
    }

    public static func randomSalt() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<saltLength).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    /// `SHA256(initiatorPublicKey || salt)`: sent in `/v1/pair/start` so the initiator's key
    /// stays hidden until the target has answered with its own.
    public static func commitment(publicKey: Data, salt: Data) -> Data {
        Data(SHA256.hash(data: publicKey + salt))
    }

    /// Constant-time check that `publicKey` and `salt` open `commitment`.
    public static func commitmentMatches(_ commitment: Data, publicKey: Data, salt: Data) -> Bool {
        let expected = Self.commitment(publicKey: publicKey, salt: salt)
        guard commitment.count == expected.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(commitment, expected) { difference |= left ^ right }
        return difference == 0
    }

    /// Derives `pairKey` and the 6-digit `confirmCode` both screens show. HKDF `info` is the
    /// transcript `code || initiatorPublicKey || targetPublicKey`.
    public func completePairing(
        remotePublicKey: Data,
        isInitiator: Bool,
        code: String
    ) throws -> (pairKey: SymmetricKey, confirmCode: String) {
        guard let remoteKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: remotePublicKey) else {
            throw PairingError.invalidPublicKey
        }

        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: remoteKey)
        let initiatorPublicKey = isInitiator ? ephemeralPublicKey : remotePublicKey
        let targetPublicKey = isInitiator ? remotePublicKey : ephemeralPublicKey
        let info = Data(code.utf8) + initiatorPublicKey + targetPublicKey

        let pairKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("ClipboardSS_PairKey".utf8),
            sharedInfo: info,
            outputByteCount: 32
        )

        let codeKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("ClipboardSS_ConfirmCode".utf8),
            sharedInfo: info,
            outputByteCount: 4
        )

        let codeValue = codeKey.withUnsafeBytes { bytes in
            bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        let confirmCode = String(format: "%06d", codeValue % 1_000_000)

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
        let message = Data(confirmationMessage(initiatorId: initiatorId, targetId: targetId).utf8)
        // Constant-time comparison of the HMAC.
        return HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: message, using: pairKey)
    }
}
