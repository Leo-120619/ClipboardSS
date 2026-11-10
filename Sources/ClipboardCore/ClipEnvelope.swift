import Foundation
import CryptoKit

func logToFile(_ message: String) {
    guard ProcessInfo.processInfo.environment["CLIPBOARDSS_DEBUG_LOG"] == "1" else { return }

    let logPath = "/tmp/clipboardss_debug.log"
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
    let dateString = formatter.string(from: Date())
    let line = "[\(dateString)] \(message)\n"
    
    if let fileHandle = FileHandle(forWritingAtPath: logPath) {
        fileHandle.seekToEndOfFile()
        if let data = line.data(using: .utf8) {
            fileHandle.write(data)
        }
        fileHandle.closeFile()
    } else {
        try? line.write(toFile: logPath, atomically: true, encoding: .utf8)
    }
}

public enum EnvelopeError: Error, Equatable {
    case encryptionFailed
    case decryptionFailed
    /// The envelope's `v` is not `ClipEnvelope.currentVersion`; servers answer 426.
    case unsupportedVersion(Int)
}

/// What an envelope is for. Bound into the AEAD associated data so an envelope sealed
/// for one endpoint cannot be replayed against another.
public enum EnvelopePurpose: String, Sendable, CaseIterable {
    case clip
    case fileOffer = "file-offer"
    case fileFinish = "file-finish"
    case fileCancel = "file-cancel"
}

/// Wire envelope v2: ChaCha20-Poly1305 over the inner JSON with associated data
/// `ClipboardSS/2|<purpose>|<source lowercase>|<recipient lowercase>`, binding sender,
/// recipient and purpose. See docs/wire-protocol.md.
public struct ClipEnvelope: Codable, Equatable, Sendable {
    public static let currentVersion = 2

    public let v: Int
    public let sourceDeviceId: UUID
    public let nonce: String
    public let ciphertext: String

    public init(v: Int = ClipEnvelope.currentVersion, sourceDeviceId: UUID, nonce: String, ciphertext: String) {
        self.v = v
        self.sourceDeviceId = sourceDeviceId
        self.nonce = nonce
        self.ciphertext = ciphertext
    }

    static func associatedData(purpose: EnvelopePurpose, sourceDeviceId: UUID, recipientDeviceId: UUID) -> Data {
        let source = sourceDeviceId.uuidString.lowercased()
        let recipient = recipientDeviceId.uuidString.lowercased()
        return Data("ClipboardSS/\(currentVersion)|\(purpose.rawValue)|\(source)|\(recipient)".utf8)
    }

    /// Seals any `Encodable` inner payload (ISO-8601 dates) for `recipientDeviceId`.
    public static func seal<T: Encodable>(
        payload: T,
        purpose: EnvelopePurpose,
        sourceDeviceId: UUID,
        recipientDeviceId: UUID,
        pairKey: SymmetricKey
    ) throws -> ClipEnvelope {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try sealPlaintext(
            try encoder.encode(payload),
            purpose: purpose,
            sourceDeviceId: sourceDeviceId,
            recipientDeviceId: recipientDeviceId,
            pairKey: pairKey
        )
    }

    /// Seals raw inner bytes. `nonce` is injectable only so the pinned vector can be reproduced.
    static func sealPlaintext(
        _ plaintext: Data,
        purpose: EnvelopePurpose,
        sourceDeviceId: UUID,
        recipientDeviceId: UUID,
        pairKey: SymmetricKey,
        nonce: ChaChaPoly.Nonce = ChaChaPoly.Nonce()
    ) throws -> ClipEnvelope {
        let aad = associatedData(purpose: purpose, sourceDeviceId: sourceDeviceId, recipientDeviceId: recipientDeviceId)
        let sealedBox: ChaChaPoly.SealedBox
        do {
            sealedBox = try ChaChaPoly.seal(plaintext, using: pairKey, nonce: nonce, authenticating: aad)
        } catch {
            throw EnvelopeError.encryptionFailed
        }
        return ClipEnvelope(
            v: currentVersion,
            sourceDeviceId: sourceDeviceId,
            nonce: Data(sealedBox.nonce).base64EncodedString(),
            ciphertext: (sealedBox.ciphertext + sealedBox.tag).base64EncodedString()
        )
    }

    /// Opens an envelope addressed to `recipientDeviceId` (the local device) for `purpose`.
    public func open<T: Decodable>(
        _ type: T.Type,
        purpose: EnvelopePurpose,
        recipientDeviceId: UUID,
        pairKey: SymmetricKey
    ) throws -> T {
        let plaintext = try openPlaintext(purpose: purpose, recipientDeviceId: recipientDeviceId, pairKey: pairKey)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(T.self, from: plaintext)
        } catch {
            throw EnvelopeError.decryptionFailed
        }
    }

    func openPlaintext(purpose: EnvelopePurpose, recipientDeviceId: UUID, pairKey: SymmetricKey) throws -> Data {
        guard v == Self.currentVersion else {
            throw EnvelopeError.unsupportedVersion(v)
        }
        guard let nonceData = Data(base64Encoded: nonce),
              let nonceObj = try? ChaChaPoly.Nonce(data: nonceData),
              let combinedData = Data(base64Encoded: ciphertext),
              combinedData.count >= 16 else {
            throw EnvelopeError.decryptionFailed
        }
        let aad = Self.associatedData(purpose: purpose, sourceDeviceId: sourceDeviceId, recipientDeviceId: recipientDeviceId)
        do {
            let sealedBox = try ChaChaPoly.SealedBox(
                nonce: nonceObj,
                ciphertext: combinedData.dropLast(16),
                tag: combinedData.suffix(16)
            )
            return try ChaChaPoly.open(sealedBox, using: pairKey, authenticating: aad)
        } catch {
            throw EnvelopeError.decryptionFailed
        }
    }
}
