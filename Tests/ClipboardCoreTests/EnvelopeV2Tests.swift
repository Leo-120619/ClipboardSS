import Foundation
import CryptoKit
import Testing
@testable import ClipboardCore

@Suite("Envelope v2")
struct EnvelopeV2Tests {
    // Pinned vector — must match docs/wire-protocol.md byte-for-byte.
    private let pairKey = SymmetricKey(data: Data((0..<32).map { UInt8($0) }))
    private let source = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let recipient = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let pinnedNonce = Data([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])
    private let pinnedPlaintext = Data(#"{"a":1}"#.utf8)
    private let pinnedCiphertextHex = "127e1dfb0b3bc54f07dfeda46cd545278be6adeef430c1"

    private struct Sample: Codable, Equatable { let a: Int }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    @Test("associated data is ClipboardSS/2|purpose|source|recipient in lowercase")
    func associatedDataFormat() {
        let aad = ClipEnvelope.associatedData(purpose: .fileOffer, sourceDeviceId: source, recipientDeviceId: recipient)
        #expect(String(decoding: aad, as: UTF8.self)
            == "ClipboardSS/2|file-offer|11111111-1111-1111-1111-111111111111|22222222-2222-2222-2222-222222222222")
    }

    @Test("v2 envelope matches the pinned vector")
    func envelopeV2MatchesPinnedVector() throws {
        let envelope = try ClipEnvelope.sealPlaintext(
            pinnedPlaintext,
            purpose: .clip,
            sourceDeviceId: source,
            recipientDeviceId: recipient,
            pairKey: pairKey,
            nonce: ChaChaPoly.Nonce(data: pinnedNonce)
        )
        #expect(envelope.v == 2)
        #expect(envelope.nonce == pinnedNonce.base64EncodedString())
        let ciphertextHex = hex(try #require(Data(base64Encoded: envelope.ciphertext)))
        #expect(ciphertextHex == pinnedCiphertextHex)

        let opened = try envelope.openPlaintext(purpose: .clip, recipientDeviceId: recipient, pairKey: pairKey)
        #expect(opened == pinnedPlaintext)
    }

    @Test("round-trips a typed payload")
    func roundTrip() throws {
        let envelope = try ClipEnvelope.seal(
            payload: Sample(a: 7), purpose: .clip,
            sourceDeviceId: source, recipientDeviceId: recipient, pairKey: pairKey
        )
        #expect(envelope.v == 2)
        #expect(envelope.sourceDeviceId == source)
        let opened = try envelope.open(Sample.self, purpose: .clip, recipientDeviceId: recipient, pairKey: pairKey)
        #expect(opened == Sample(a: 7))
    }

    @Test("open fails when the purpose differs")
    func openFailsWithWrongPurpose() throws {
        let envelope = try ClipEnvelope.seal(
            payload: Sample(a: 1), purpose: .fileOffer,
            sourceDeviceId: source, recipientDeviceId: recipient, pairKey: pairKey
        )
        for purpose in [EnvelopePurpose.clip, .fileFinish, .fileCancel] {
            #expect(throws: EnvelopeError.decryptionFailed) {
                _ = try envelope.open(Sample.self, purpose: purpose, recipientDeviceId: recipient, pairKey: pairKey)
            }
        }
    }

    @Test("open fails when the envelope is reflected back to its sender")
    func openFailsWhenReflectedToSender() throws {
        let envelope = try ClipEnvelope.seal(
            payload: Sample(a: 1), purpose: .clip,
            sourceDeviceId: source, recipientDeviceId: recipient, pairKey: pairKey
        )
        // The attacker relabels the envelope as coming from the recipient and sends it to the source.
        let reflected = ClipEnvelope(v: 2, sourceDeviceId: recipient, nonce: envelope.nonce, ciphertext: envelope.ciphertext)
        #expect(throws: EnvelopeError.decryptionFailed) {
            _ = try reflected.open(Sample.self, purpose: .clip, recipientDeviceId: source, pairKey: pairKey)
        }
        // Even unrelabelled, the original sender is not the intended recipient.
        #expect(throws: EnvelopeError.decryptionFailed) {
            _ = try envelope.open(Sample.self, purpose: .clip, recipientDeviceId: source, pairKey: pairKey)
        }
    }

    @Test("open fails for a recipient the envelope was not sealed for")
    func openFailsWithWrongRecipient() throws {
        let envelope = try ClipEnvelope.seal(
            payload: Sample(a: 1), purpose: .clip,
            sourceDeviceId: source, recipientDeviceId: recipient, pairKey: pairKey
        )
        #expect(throws: EnvelopeError.decryptionFailed) {
            _ = try envelope.open(Sample.self, purpose: .clip, recipientDeviceId: UUID(), pairKey: pairKey)
        }
    }

    @Test("open rejects a v1 envelope as unsupported")
    func openRejectsV1() throws {
        let envelope = try ClipEnvelope.seal(
            payload: Sample(a: 1), purpose: .clip,
            sourceDeviceId: source, recipientDeviceId: recipient, pairKey: pairKey
        )
        let v1 = ClipEnvelope(v: 1, sourceDeviceId: source, nonce: envelope.nonce, ciphertext: envelope.ciphertext)
        #expect(throws: EnvelopeError.unsupportedVersion(1)) {
            _ = try v1.open(Sample.self, purpose: .clip, recipientDeviceId: recipient, pairKey: pairKey)
        }
    }
}
