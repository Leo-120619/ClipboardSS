import Foundation

/// Remembers the folder chosen for one run of back-to-back received files.
///
/// A multi-file share arrives as separate transfers — the sender uploads them one
/// after another — so "ask every time" would otherwise open a folder picker per
/// file. The first answer of a run is reused for the rest of it, a cancel
/// included, which makes a three-file share ask once and keep every file
/// together. The run ends once no file has arrived for ``window`` seconds.
struct ReceiveBatchDestination {
    enum Decision: Equatable {
        case folder(URL)
        /// The picker was dismissed: leave the rest of the run where it landed.
        case declined
    }

    /// How long after the last received file the run's answer stays valid.
    let window: TimeInterval
    private var decision: Decision?
    private var expiresAt: Date = .distantPast

    init(window: TimeInterval = 60) {
        self.window = window
    }

    /// The answer already given for this run, or `nil` when the user must be asked.
    /// Reading extends the run, so a slow batch stays grouped.
    mutating func decision(now: Date) -> Decision? {
        guard let decision, now < expiresAt else {
            self.decision = nil
            expiresAt = .distantPast
            return nil
        }
        expiresAt = now.addingTimeInterval(window)
        return decision
    }

    /// Records the user's answer and starts (or restarts) the run's window.
    mutating func record(_ decision: Decision, now: Date) {
        self.decision = decision
        expiresAt = now.addingTimeInterval(window)
    }
}
