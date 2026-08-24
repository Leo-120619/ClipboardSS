import Foundation
import ClipboardCore

/// UI-facing state for a single in-flight or finished file transfer (either direction).
struct FileTransferState: Identifiable, Equatable {
    enum Direction: Equatable {
        case sending
        case receiving
    }

    enum Status: Equatable {
        case inProgress
        case completed
        case failed(String)
        case cancelled
    }

    let id: UUID
    /// Stable key: the protocol `transferId` for receives, or the UI id string for sends.
    let key: String
    let fileName: String
    let direction: Direction
    var progress: Double
    var status: Status
    var destinationURL: URL?

    var isActive: Bool { status == .inProgress }
}

/// Files dropped onto the window that need a destination device chosen (more than one
/// reachable paired device). Presented as a picker sheet.
struct PendingSend: Identifiable, Equatable {
    let id = UUID()
    let files: [URL]
}

/// Thread-safe cancellation flag polled by `FileSender.sendFile(isCancelled:)`.
final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

/// Mutable bridge for receiver events. The `FileReceiver` is created before the
/// `AppModel`, so the handler is set once the model exists. Thread-safe because events
/// arrive off the main actor.
final class FileTransferEventSink: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (FileTransferReceiveEvent) -> Void)?

    func setHandler(_ handler: @escaping @Sendable (FileTransferReceiveEvent) -> Void) {
        lock.lock(); self.handler = handler; lock.unlock()
    }

    func emit(_ event: FileTransferReceiveEvent) {
        lock.lock(); let handler = self.handler; lock.unlock()
        handler?(event)
    }
}
