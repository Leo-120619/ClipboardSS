import Foundation

/// Moves an unreadable state file aside so the app can start with empty state instead of refusing to launch.
/// The copy is kept next to the original as `<name>.corrupt-<yyyyMMdd-HHmmss UTC>` (same format on every platform).
public enum CorruptStateFile {
    public static func timestamp(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    /// Renames `url` to its quarantine name and returns the new location. Never overwrites an earlier copy.
    @discardableResult
    public static func quarantine(
        _ url: URL,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> URL {
        let baseName = "\(url.lastPathComponent).corrupt-\(timestamp(for: now))"
        let directory = url.deletingLastPathComponent()
        var destination = directory.appendingPathComponent(baseName)
        var suffix = 2
        while fileManager.fileExists(atPath: destination.path) {
            destination = directory.appendingPathComponent("\(baseName)-\(suffix)")
            suffix += 1
        }
        try fileManager.moveItem(at: url, to: destination)
        return destination
    }
}
