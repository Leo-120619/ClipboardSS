import Foundation

/// Outcome of a freshness / replay check on an opened envelope.
public enum ReplayCheck: Sendable, Equatable {
    case ok
    /// `|now - sentAt|` exceeds the freshness window: the clocks disagree, or the
    /// envelope is old. Receivers answer `400 {"status":"stale"}`.
    case stale
    /// The `(sourceDeviceId, nonce)` pair was already accepted within the retention
    /// period. Receivers answer `409 {"status":"replayed"}`.
    case replayed
}

/// Rejects stale and replayed envelopes. Call `check` only after the AEAD open
/// succeeded (so `sentAt` is authenticated and junk never fills the set), and before
/// any side effect. One instance per receiver process, shared by every envelope
/// endpoint. See docs/wire-protocol.md ("Freshness and replay protection").
public actor ReplayGuard {
    public static let defaultWindow: TimeInterval = 300
    public static let defaultRetention: TimeInterval = 600

    private let window: TimeInterval
    private let retention: TimeInterval
    private let now: @Sendable () -> Date
    /// Accepted `(source, nonce)` keys and when they were accepted.
    private var seen: [String: Date] = [:]

    public init(
        window: TimeInterval = ReplayGuard.defaultWindow,
        retention: TimeInterval = ReplayGuard.defaultRetention,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.window = window
        self.retention = retention
        self.now = now
    }

    public func check(sourceDeviceId: UUID, nonce: String, sentAt: Date) -> ReplayCheck {
        let current = now()
        let cutoff = current.addingTimeInterval(-retention)
        seen = seen.filter { $0.value >= cutoff }

        guard abs(current.timeIntervalSince(sentAt)) <= window else { return .stale }

        let key = Self.key(sourceDeviceId: sourceDeviceId, nonce: nonce)
        if seen[key] != nil { return .replayed }
        seen[key] = current
        return .ok
    }

    /// Keys on the decoded nonce bytes, so an alternative spelling of the same base64
    /// nonce cannot slip past the set.
    static func key(sourceDeviceId: UUID, nonce: String) -> String {
        let canonicalNonce = Data(base64Encoded: nonce)?.base64EncodedString() ?? nonce
        return "\(sourceDeviceId.uuidString.lowercased())|\(canonicalNonce)"
    }
}
