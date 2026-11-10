import Foundation
import Testing
@testable import ClipboardCore

@Suite("Debug log")
struct DebugLogTests {
    @Test("the shared debug log lives under ~/Library/Logs/ClipboardSS")
    func defaultLocationIsUserLogsDirectory() {
        let expected = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/ClipboardSS/debug.log")
        #expect(DebugLogger.defaultFileURL.standardizedFileURL.path == expected.standardizedFileURL.path)
    }

    @Test("the debug log file is 0600 in a 0700 directory and appends lines")
    func debugLogIsPrivateToTheUser() throws {
        let directory = try temporaryDirectory().appendingPathComponent("Logs/ClipboardSS", isDirectory: true)
        let fileURL = directory.appendingPathComponent("debug.log")
        let logger = DebugLogger(fileURL: fileURL, isEnabled: true)

        logger.write("first")
        logger.write("second")

        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(contents.contains("first"))
        #expect(contents.contains("second"))
        #expect(try permissions(of: fileURL) == 0o600)
        #expect(try permissions(of: directory) == 0o700)
    }

    @Test("a disabled logger writes nothing")
    func disabledLoggerWritesNothing() throws {
        let fileURL = try temporaryDirectory().appendingPathComponent("Logs/debug.log")
        DebugLogger(fileURL: fileURL, isEnabled: false).write("ignored")
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}
