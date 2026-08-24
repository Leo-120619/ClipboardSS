import Foundation
import CryptoKit

public enum FileTransferCryptoError: Error {
    case chunkTooShort
    case sealFailed
    case openFailed
}

/// Per-transfer chunk crypto. Canonical spec: docs/wire-protocol.md.
///
/// ```
/// fileKey    = HKDF-SHA256(secret=pairKey, salt="ClipboardSS_FileKey",
///                          info=ASCII lowercase transferId, L=32)
/// chunkNonce = 0x00000000 || uint64_big_endian(chunkIndex)
/// chunkBody  = ChaCha20-Poly1305(fileKey, chunkNonce, plaintext) = ciphertext || tag
/// ```
public enum FileTransferCrypto {
    public static func deriveFileKey(pairKey: SymmetricKey, transferId: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: pairKey,
            salt: Data(FileTransferConstants.fileKeySalt.utf8),
            info: Data(transferId.lowercased().utf8),
            outputByteCount: 32
        )
    }

    /// 4 zero bytes followed by the big-endian 8-byte chunk index (12 bytes total).
    public static func nonce(forChunk index: UInt64) -> Data {
        var data = Data(repeating: 0, count: 4)
        var bigEndian = index.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
        return data
    }

    public static func sealChunk(_ plaintext: Data, fileKey: SymmetricKey, index: UInt64) throws -> Data {
        guard let nonce = try? ChaChaPoly.Nonce(data: nonce(forChunk: index)),
              let box = try? ChaChaPoly.seal(plaintext, using: fileKey, nonce: nonce) else {
            throw FileTransferCryptoError.sealFailed
        }
        return box.ciphertext + box.tag
    }

    public static func openChunk(_ body: Data, fileKey: SymmetricKey, index: UInt64) throws -> Data {
        guard body.count >= 16 else { throw FileTransferCryptoError.chunkTooShort }
        guard let nonce = try? ChaChaPoly.Nonce(data: nonce(forChunk: index)),
              let box = try? ChaChaPoly.SealedBox(
                nonce: nonce,
                ciphertext: body.dropLast(16),
                tag: body.suffix(16)
              ),
              let plaintext = try? ChaChaPoly.open(box, using: fileKey) else {
            throw FileTransferCryptoError.openFailed
        }
        return plaintext
    }
}
