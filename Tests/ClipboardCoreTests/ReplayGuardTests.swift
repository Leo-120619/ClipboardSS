import Foundation
import CryptoKit
import Testing
@testable import ClipboardCore

@Suite("ReplayGuard")
struct ReplayGuardTests {
    private let source = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeGuard(_ clock: MutableClock) -> ReplayGuard {
        ReplayGuard(window: 300, retention: 600, now: clock.now)
    }

    @Test("a fresh message is accepted")
    func freshMessageIsAccepted() async {
        let clock = MutableClock(start)
        let replayGuard = makeGuard(clock)
        #expect(await replayGuard.check(sourceDeviceId: source, nonce: "AAAAAAAAAAAAAAAB", sentAt: start) == .ok)
    }

    @Test("the same nonce twice is replayed")
    func sameNonceTwiceIsReplayed() async {
        let clock = MutableClock(start)
        let replayGuard = makeGuard(clock)
        #expect(await replayGuard.check(sourceDeviceId: source, nonce: "AAAAAAAAAAAAAAAB", sentAt: start) == .ok)
        clock.advance(by: 5)
        #expect(await replayGuard.check(sourceDeviceId: source, nonce: "AAAAAAAAAAAAAAAB", sentAt: start) == .replayed)
        // Another sender may use the same nonce bytes under its own key.
        #expect(await replayGuard.check(sourceDeviceId: UUID(), nonce: "AAAAAAAAAAAAAAAB", sentAt: start) == .ok)
    }

    @Test("sentAt four minutes off either way is accepted (Review Focus 1)")
    func sentAtFourMinutesOffIsAccepted() async {
        let clock = MutableClock(start)
        let replayGuard = makeGuard(clock)
        #expect(await replayGuard.check(sourceDeviceId: source, nonce: "AAAAAAAAAAAAAAAB", sentAt: start.addingTimeInterval(-240)) == .ok)
        #expect(await replayGuard.check(sourceDeviceId: source, nonce: "AAAAAAAAAAAAAAAC", sentAt: start.addingTimeInterval(240)) == .ok)
    }

    @Test("sentAt twenty minutes off either way is stale (Review Focus 1)")
    func sentAtTwentyMinutesOffIsStale() async {
        let clock = MutableClock(start)
        let replayGuard = makeGuard(clock)
        #expect(await replayGuard.check(sourceDeviceId: source, nonce: "AAAAAAAAAAAAAAAB", sentAt: start.addingTimeInterval(-1_200)) == .stale)
        #expect(await replayGuard.check(sourceDeviceId: source, nonce: "AAAAAAAAAAAAAAAC", sentAt: start.addingTimeInterval(1_200)) == .stale)
        // The window boundary itself is inclusive.
        #expect(await replayGuard.check(sourceDeviceId: source, nonce: "AAAAAAAAAAAAAAAD", sentAt: start.addingTimeInterval(-300)) == .ok)
        #expect(await replayGuard.check(sourceDeviceId: source, nonce: "AAAAAAAAAAAAAAAE", sentAt: start.addingTimeInterval(-301)) == .stale)
    }

    @Test("a stale message is not remembered")
    func staleMessageIsNotRemembered() async {
        let clock = MutableClock(start)
        let replayGuard = makeGuard(clock)
        #expect(await replayGuard.check(sourceDeviceId: source, nonce: "AAAAAAAAAAAAAAAB", sentAt: start.addingTimeInterval(-1_200)) == .stale)
        #expect(await replayGuard.check(sourceDeviceId: source, nonce: "AAAAAAAAAAAAAAAB", sentAt: start) == .ok)
    }

    @Test("entries expire after the retention period")
    func entriesExpireAfterRetention() async {
        let clock = MutableClock(start)
        let replayGuard = makeGuard(clock)
        #expect(await replayGuard.check(sourceDeviceId: source, nonce: "AAAAAAAAAAAAAAAB", sentAt: start) == .ok)
        clock.advance(by: 599)
        #expect(await replayGuard.check(sourceDeviceId: source, nonce: "AAAAAAAAAAAAAAAB", sentAt: clock.now()) == .replayed)
        clock.advance(by: 2)
        #expect(await replayGuard.check(sourceDeviceId: source, nonce: "AAAAAAAAAAAAAAAB", sentAt: clock.now()) == .ok)
    }

    @Test("source ids are compared case-insensitively and nonces by their bytes")
    func keysAreCanonical() {
        #expect(ReplayGuard.key(sourceDeviceId: source, nonce: "AAAAAAAAAAAAAAAB")
            == "11111111-1111-1111-1111-111111111111|AAAAAAAAAAAAAAAB")
    }

    // MARK: - sentAt on the wire

    private let pairKey = SymmetricKey(data: Data((0..<32).map { UInt8($0) }))
    private let recipient = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private struct Sample: Codable, Equatable { let a: Int }

    @Test("seal stamps sentAt inside the encrypted payload in whole-second UTC")
    func sealStampsSentAt() throws {
        // docs/wire-protocol.md freshness vector: 2026-11-10T12:00:00.456Z → "2026-11-10T12:00:00Z".
        let sentAt = Date(timeIntervalSince1970: 1_794_312_000.456)
        let envelope = try ClipEnvelope.seal(
            payload: Sample(a: 1), purpose: .clip,
            sourceDeviceId: source, recipientDeviceId: recipient, pairKey: pairKey, sentAt: sentAt
        )
        let plaintext = try envelope.openPlaintext(purpose: .clip, recipientDeviceId: recipient, pairKey: pairKey)
        let object = try #require(try JSONSerialization.jsonObject(with: plaintext) as? [String: Any])
        #expect(object["sentAt"] as? String == "2026-11-10T12:00:00Z")
        #expect(object["a"] as? Int == 1)

        let opened = try envelope.openStamped(Sample.self, purpose: .clip, recipientDeviceId: recipient, pairKey: pairKey)
        #expect(opened.payload == Sample(a: 1))
        #expect(opened.sentAt == Date(timeIntervalSince1970: 1_794_312_000))
    }

    @Test("an envelope without sentAt opens as infinitely old")
    func missingSentAtIsStale() throws {
        let envelope = try ClipEnvelope.sealPlaintext(
            Data(#"{"a":1}"#.utf8), purpose: .clip,
            sourceDeviceId: source, recipientDeviceId: recipient, pairKey: pairKey
        )
        let opened = try envelope.openStamped(Sample.self, purpose: .clip, recipientDeviceId: recipient, pairKey: pairKey)
        #expect(opened.sentAt == .distantPast)
    }

    @Test("sentAt written by Dart and .NET (whole-second Z) parses")
    func parsesCrossPlatformSentAt() throws {
        let envelope = try ClipEnvelope.sealPlaintext(
            Data(#"{"a":1,"sentAt":"2026-11-10T12:00:00Z"}"#.utf8), purpose: .clip,
            sourceDeviceId: source, recipientDeviceId: recipient, pairKey: pairKey
        )
        let opened = try envelope.openStamped(Sample.self, purpose: .clip, recipientDeviceId: recipient, pairKey: pairKey)
        #expect(opened.sentAt == Date(timeIntervalSince1970: 1_794_312_000))
    }
}
