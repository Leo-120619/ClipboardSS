import Foundation
import Testing
@testable import ClipboardCore

@Suite("ClipStore")
struct ClipStoreTests {
    @Test("stores text clips newest first and reloads them from disk")
    func storesTextClipsNewestFirstAndReloads() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let store = try ClipStore(storageDirectory: temporaryDirectory(), now: clock.now)

        let first = try store.addText("first")
        clock.advance(by: 10)
        let second = try store.addText("second")

        #expect(store.items.map(\.id) == [second.id, first.id])

        let reloaded = try ClipStore(storageDirectory: store.storageDirectory, now: clock.now)
        #expect(reloaded.items.map(\.text) == ["second", "first"])
    }

    @Test("deduplicates text content by moving an existing clip to the top")
    func deduplicatesTextClips() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 2_000))
        let store = try ClipStore(storageDirectory: temporaryDirectory(), now: clock.now)

        let first = try store.addText("repeat")
        clock.advance(by: 20)
        let duplicate = try store.addText("repeat")

        #expect(first.id == duplicate.id)
        #expect(store.items.count == 1)
        #expect(store.items.first?.createdAt == clock.now())
    }

    @Test("removes only unpinned clips older than seven days")
    func removesOnlyUnpinnedExpiredClips() throws {
        let start = Date(timeIntervalSince1970: 3_000)
        let clock = TestClock(start)
        let store = try ClipStore(storageDirectory: temporaryDirectory(), now: clock.now)

        let expired = try store.addText("expired")
        let pinned = try store.addText("pinned")
        try store.setPinned(pinned.id, true)
        clock.advance(by: (8 * 24 * 60 * 60) + 1)
        let fresh = try store.addText("fresh")

        try store.cleanupExpiredClips()

        #expect(store.items.map(\.id).contains(expired.id) == false)
        #expect(store.items.map(\.id).contains(pinned.id))
        #expect(store.items.map(\.id).contains(fresh.id))
    }

    @Test("stores image clips as files and reloads metadata")
    func storesImageClipsAsFiles() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 4_000))
        let store = try ClipStore(storageDirectory: temporaryDirectory(), now: clock.now)
        let imageData = Data([0x89, 0x50, 0x4E, 0x47])

        let clip = try store.addImageData(imageData, fileExtension: "png", previewText: "Screenshot")

        #expect(clip.type == .image)
        #expect(clip.previewText == "Screenshot")
        #expect(try Data(contentsOf: clip.resolvedImageURL(baseDirectory: store.storageDirectory)) == imageData)

        let reloaded = try ClipStore(storageDirectory: store.storageDirectory, now: clock.now)
        #expect(reloaded.items.first?.type == .image)
        #expect(reloaded.items.first?.imagePath == clip.imagePath)
    }

    @Test("filters pinned clips across text and image items")
    func filtersPinnedClips() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 5_000))
        let store = try ClipStore(storageDirectory: temporaryDirectory(), now: clock.now)

        let pinnedText = try store.addText("important text")
        let unpinnedText = try store.addText("normal text")
        let pinnedImage = try store.addImageData(Data([0x01, 0x02, 0x03]), fileExtension: "png", previewText: "Pinned image")

        try store.setPinned(pinnedText.id, true)
        try store.setPinned(pinnedImage.id, true)

        let pinnedClips = store.clips(matching: "", filter: .pinned)

        #expect(pinnedClips.map(\.id).contains(pinnedText.id))
        #expect(pinnedClips.map(\.id).contains(pinnedImage.id))
        #expect(pinnedClips.map(\.id).contains(unpinnedText.id) == false)
    }
}

private final class TestClock {
    private var current: Date

    init(_ current: Date) {
        self.current = current
    }

    func now() -> Date {
        current
    }

    func advance(by seconds: TimeInterval) {
        current = current.addingTimeInterval(seconds)
    }
}

func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ClipboardSSTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
