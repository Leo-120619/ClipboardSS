import Foundation

/// Opt-in debug log (`CLIPBOARDSS_DEBUG_LOG=1`). One implementation shared by the core
/// library and the app; tests build their own instance pointed at a temp directory.
public final class DebugLogger: @unchecked Sendable {
    public static let shared = DebugLogger(
        fileURL: DebugLogger.defaultFileURL,
        isEnabled: ProcessInfo.processInfo.environment["CLIPBOARDSS_DEBUG_LOG"] == "1"
    )

    /// `~/Library/Logs/ClipboardSS/debug.log` — per user, unlike the old world-readable `/tmp` file.
    public static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/ClipboardSS", isDirectory: true)
            .appendingPathComponent("debug.log")
    }

    public let fileURL: URL
    public let isEnabled: Bool
    private let lock = NSLock()

    public init(fileURL: URL, isEnabled: Bool) {
        self.fileURL = fileURL
        self.isEnabled = isEnabled
    }

    public func write(_ message: String) {
        guard isEnabled else { return }
        let line = "[\(Date())] \(message)\n"
        lock.lock()
        defer { lock.unlock() }

        // Directory 0700 and file 0600, re-applied in case they were created looser.
        let directory = fileURL.deletingLastPathComponent()
        let fileManager = FileManager.default
        try? fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let descriptor = open(fileURL.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        fchmod(descriptor, 0o600)
        let bytes = Array(line.utf8)
        _ = bytes.withUnsafeBufferPointer { buffer in
            Foundation.write(descriptor, buffer.baseAddress, buffer.count)
        }
    }
}

public func logToFile(_ message: String) {
    DebugLogger.shared.write(message)
}
