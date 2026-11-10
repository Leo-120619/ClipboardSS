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
}
