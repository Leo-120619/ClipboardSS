import ClipboardCore
import Foundation
import Testing

@Suite("Share inbox")
struct ShareInboxTests {
    private let root: URL
    private let outbox: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShareInboxTests-\(UUID().uuidString)", isDirectory: true)
        outbox = root.appendingPathComponent("ShareOutbox", isDirectory: true)
        try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
    }

    private func makeDrop(names: [String], prepare: (URL) throws -> Void) throws -> URL {
        let drop = outbox.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: drop, withIntermediateDirectories: true)
        try prepare(drop)
        let manifest = ShareManifest(id: drop.lastPathComponent, fileNames: names)
        try JSONEncoder().encode(manifest).write(to: drop.appendingPathComponent("manifest.json"))
        return drop
    }

    @Test("a well-formed drop is returned")
    func validDropIsReturned() throws {
        let drop = try makeDrop(names: ["photo.png"]) { dir in
            try Data("png".utf8).write(to: dir.appendingPathComponent("photo.png"))
        }

        let drops = ShareInbox.pendingDrops(in: outbox)

        #expect(drops.count == 1)
        #expect(drops.first?.fileURLs.map(\.lastPathComponent) == ["photo.png"])
        #expect(drops.first?.directory.standardizedFileURL == drop.standardizedFileURL)
    }

    @Test("a rejected or incomplete drop older than 24 hours is removed; a fresh one is kept")
    func staleRejectedDropIsRemoved() throws {
        let staleIncomplete = outbox.appendingPathComponent("stale-incomplete", isDirectory: true)
        try FileManager.default.createDirectory(at: staleIncomplete, withIntermediateDirectories: true)
        try Data("png".utf8).write(to: staleIncomplete.appendingPathComponent("photo.png"))
        let staleRejected = try makeDrop(names: ["missing.png"]) { _ in }
        let fresh = outbox.appendingPathComponent("fresh-incomplete", isDirectory: true)
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        let old = Date().addingTimeInterval(-25 * 60 * 60)
        for dir in [staleIncomplete, staleRejected] {
            try FileManager.default.setAttributes([.creationDate: old, .modificationDate: old], ofItemAtPath: dir.path)
        }

        #expect(ShareInbox.pendingDrops(in: outbox).isEmpty)

        #expect(!FileManager.default.fileExists(atPath: staleIncomplete.path))
        #expect(!FileManager.default.fileExists(atPath: staleRejected.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
    }

    @Test("a manifest name that climbs out of the drop is rejected")
    func manifestNameWithParentTraversalIsRejected() throws {
        try Data("secret".utf8).write(to: root.appendingPathComponent("secret.txt"))
        _ = try makeDrop(names: ["../../secret.txt"]) { _ in }

        #expect(ShareInbox.pendingDrops(in: outbox).isEmpty)
    }

    @Test("a manifest entry that is a symlink is rejected")
    func manifestSymlinkIsRejected() throws {
        let outside = root.appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: outside)
        _ = try makeDrop(names: ["link.txt"]) { dir in
            try FileManager.default.createSymbolicLink(
                at: dir.appendingPathComponent("link.txt"),
                withDestinationURL: outside
            )
        }

        #expect(ShareInbox.pendingDrops(in: outbox).isEmpty)
    }

    @Test("a tampered drop is skipped while a valid sibling is returned")
    func tamperedDropSkippedValidSiblingReturned() throws {
        let valid = try makeDrop(names: ["photo.png"]) { dir in
            try Data("png".utf8).write(to: dir.appendingPathComponent("photo.png"))
        }
        _ = try makeDrop(names: ["ok.txt", "../ok.txt"]) { dir in
            try Data("ok".utf8).write(to: dir.appendingPathComponent("ok.txt"))
        }

        let drops = ShareInbox.pendingDrops(in: outbox)

        #expect(drops.map { $0.directory.standardizedFileURL } == [valid.standardizedFileURL])
    }
}

@Suite("Share handoff import")
struct ShareImportTests {
    private let root: URL
    private let outbox: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShareImportTests-\(UUID().uuidString)", isDirectory: true)
        outbox = root.appendingPathComponent("ShareOutbox", isDirectory: true)
        try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
    }

    @Test("a shared file, folder and in-memory item become one complete drop; the folder is zipped")
    func importBuildsCompleteDrop() throws {
        let file = root.appendingPathComponent("notes.txt")
        try Data("notes".utf8).write(to: file)
        let folder = root.appendingPathComponent("Schema Therapy 2", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("inner".utf8).write(to: folder.appendingPathComponent("sub/inner.txt"))

        try ShareInbox.importItems(
            [.init(path: file.path), .init(path: folder.path), .init(name: "../shot.png", data: Data("png".utf8))],
            into: outbox
        )

        let drops = ShareInbox.pendingDrops(in: outbox)
        #expect(drops.count == 1)
        #expect(drops.first?.fileURLs.map(\.lastPathComponent) == ["notes.txt", "Schema Therapy 2.zip", "shot.png"])
        #expect(FileManager.default.fileExists(atPath: folder.path))

        // The archive unpacks to the folder itself with its contents.
        let archive = try #require(drops.first?.fileURLs[1])
        let unpacked = root.appendingPathComponent("unpacked", isDirectory: true)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", archive.path, unpacked.path]
        try unzip.run()
        unzip.waitUntilExit()
        let inner = unpacked.appendingPathComponent("Schema Therapy 2/sub/inner.txt")
        #expect((try? Data(contentsOf: inner)) == Data("inner".utf8))
    }

    @Test("a share with an unreadable item leaves no drop behind")
    func failedImportLeavesNothing() throws {
        let file = root.appendingPathComponent("notes.txt")
        try Data("notes".utf8).write(to: file)

        #expect(throws: (any Error).self) {
            try ShareInbox.importItems(
                [.init(path: file.path), .init(path: root.appendingPathComponent("missing.txt").path)],
                into: outbox
            )
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outbox.path).isEmpty)
    }

    @Test("items posted by the extension are taken once by the host")
    func handoffRoundTrip() throws {
        let items: [ShareHandoff.Item] = [.init(path: "/tmp/a folder"), .init(name: "shot.png", data: Data("png".utf8))]

        let id = try ShareHandoff.post(items)

        #expect(ShareHandoff.take(id: id) == items)
        #expect(ShareHandoff.take(id: id) == nil)
        #expect(ShareHandoff.take(id: "not-an-id") == nil)
    }
}
