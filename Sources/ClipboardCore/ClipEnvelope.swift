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

public enum EnvelopeError: Error {
    case encryptionFailed
    case decryptionFailed
}

public struct ClipEnvelope: Codable, Equatable, Sendable {
    public let v: Int
    public let sourceDeviceId: UUID
    public let nonce: String
    public let ciphertext: String

    public init(v: Int = 1, sourceDeviceId: UUID, nonce: String, ciphertext: String) {
        self.v = v
        self.sourceDeviceId = sourceDeviceId
        self.nonce = nonce
        self.ciphertext = ciphertext
    }

    public static func seal(
        payload: ClipPayload,
        sourceDeviceId: UUID,
        pairKey: SymmetricKey
    ) throws -> ClipEnvelope {
        try sealEncoded(payload: payload, sourceDeviceId: sourceDeviceId, pairKey: pairKey)
    }

    /// Seals any `Encodable` inner payload into an envelope, matching the ClipPayload
    /// path exactly (ISO-8601 dates, ChaCha20-Poly1305, ciphertext||tag base64). Used by
    /// the file-transfer control messages (offer / finish / cancel).
    public static func seal<T: Encodable>(
        payload: T,
        sourceDeviceId: UUID,
        pairKey: SymmetricKey
    ) throws -> ClipEnvelope {
        try sealEncoded(payload: payload, sourceDeviceId: sourceDeviceId, pairKey: pairKey)
    }

    private static func sealEncoded<T: Encodable>(
        payload: T,
        sourceDeviceId: UUID,
        pairKey: SymmetricKey
    ) throws -> ClipEnvelope {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let plaintext = try encoder.encode(payload)

        let sealedBox = try ChaChaPoly.seal(plaintext, using: pairKey)
        let combinedCiphertext = sealedBox.ciphertext + sealedBox.tag

        return ClipEnvelope(
            v: 1,
            sourceDeviceId: sourceDeviceId,
            nonce: Data(sealedBox.nonce).base64EncodedString(),
            ciphertext: combinedCiphertext.base64EncodedString()
        )
    }

    /// Opens an envelope into an arbitrary `Decodable` inner payload.
    public func open<T: Decodable>(_ type: T.Type, pairKey: SymmetricKey) throws -> T {
        guard let nonceData = Data(base64Encoded: nonce),
              let nonceObj = try? ChaChaPoly.Nonce(data: nonceData),
              let combinedData = Data(base64Encoded: ciphertext),
              combinedData.count >= 16 else {
            throw EnvelopeError.decryptionFailed
        }
        do {
            let sealedBox = try ChaChaPoly.SealedBox(
                nonce: nonceObj,
                ciphertext: combinedData.dropLast(16),
                tag: combinedData.suffix(16)
            )
            let plaintext = try ChaChaPoly.open(sealedBox, using: pairKey)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(T.self, from: plaintext)
        } catch {
            throw EnvelopeError.decryptionFailed
        }
    }

    public func open(pairKey: SymmetricKey) throws -> ClipPayload {
        try open(ClipPayload.self, pairKey: pairKey)
    }
}
