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

    public func open(pairKey: SymmetricKey) throws -> ClipPayload {
        logToFile("ClipEnvelope.open: starting decryption")
        guard let nonceData = Data(base64Encoded: nonce) else {
            logToFile("ClipEnvelope.open: nonce is not valid base64")
            throw EnvelopeError.decryptionFailed
        }
        logToFile("ClipEnvelope.open: nonceData bytes count = \(nonceData.count)")
        
        guard let nonceObj = try? ChaChaPoly.Nonce(data: nonceData) else {
            logToFile("ClipEnvelope.open: failed to parse Nonce")
            throw EnvelopeError.decryptionFailed
        }
        
        guard let combinedData = Data(base64Encoded: ciphertext) else {
            logToFile("ClipEnvelope.open: ciphertext is not valid base64")
            throw EnvelopeError.decryptionFailed
        }
        logToFile("ClipEnvelope.open: combinedData bytes count = \(combinedData.count)")
        
        guard combinedData.count >= 16 else {
            logToFile("ClipEnvelope.open: combinedData is too short")
            throw EnvelopeError.decryptionFailed
        }

        do {
            let ciphertextData = combinedData.dropLast(16)
            let tagData = combinedData.suffix(16)
            logToFile("ClipEnvelope.open: ciphertextData count = \(ciphertextData.count), tagData count = \(tagData.count)")
            
            let sealedBox = try ChaChaPoly.SealedBox(nonce: nonceObj, ciphertext: ciphertextData, tag: tagData)
            
            let plaintext = try ChaChaPoly.open(sealedBox, using: pairKey)
            logToFile("ClipEnvelope.open: decryption succeeded, plaintext count = \(plaintext.count)")
            
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(ClipPayload.self, from: plaintext)
        } catch {
            logToFile("ClipEnvelope.open: decryption or decoding failed with error: \(error)")
            throw EnvelopeError.decryptionFailed
        }
    }
}
