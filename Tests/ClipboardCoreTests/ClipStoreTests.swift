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

    @Test("cleanup does not rewrite metadata when nothing expired")
    func cleanupWithoutExpiredClipsSkipsSave() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 3_500))
        let store = try ClipStore(storageDirectory: temporaryDirectory(), now: clock.now)
        try store.addText("fresh")
        let metadataURL = store.storageDirectory.appendingPathComponent("clips.json")
        try FileManager.default.removeItem(at: metadataURL)

        try store.cleanupExpiredClips()

        #expect(FileManager.default.fileExists(atPath: metadataURL.path) == false)
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

    @Test(
        "sanitizes peer-supplied image extensions",
        arguments: [
            ("png", "png"),
            ("JPG", "jpg"),
            ("", "png"),
            ("x/../../evil.cmd", "png"),
            ("a.b", "png"),
            ("toolongext", "png"),
        ]
    )
    func sanitizesImageExtension(input: String, expected: String) {
        #expect(sanitizedImageExtension(input) == expected)
    }

    @Test("writes an image with a traversal extension inside the Images directory")
    func addImageDataWithTraversalExtensionWritesInsideImagesDirectory() throws {
        let root = try temporaryDirectory()
        let storage = root.appendingPathComponent("store", isDirectory: true)
        let store = try ClipStore(storageDirectory: storage)

        let clip = try store.addImageData(Data([0x89, 0x50, 0x4E, 0x47]), fileExtension: "x/../../evil.cmd")

        let imagePath = try #require(clip.imagePath)
        #expect(imagePath.hasPrefix("Images/"))
        #expect(imagePath.hasSuffix(".png"))
        #expect(!imagePath.contains(".."))
        let images = try FileManager.default.contentsOfDirectory(atPath: storage.appendingPathComponent("Images").path)
        #expect(images.count == 1)
    }

    @Test("history keeps at most the unpinned-clip and image-byte caps, evicting oldest unpinned first")
    func historyIsCappedByCountAndSize() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 5_000))
        let store = try ClipStore(
            storageDirectory: temporaryDirectory(),
            now: clock.now,
            maxUnpinnedClips: 3,
            maxImageBytes: 10
        )

        let pinned = try store.addText("pinned")
        try store.setPinned(pinned.id, true)
        var texts: [ClipItem] = []
        for index in 0..<5 {
            clock.advance(by: 1)
            texts.append(try store.addText("text \(index)"))
        }

        // Count cap: the three newest unpinned clips survive; the pinned one is never evicted.
        #expect(store.items.map(\.id) == [texts[4].id, texts[3].id, texts[2].id, pinned.id])

        // Size cap: 4 + 4 + 4 bytes of images exceeds 10, so the oldest image goes, file included.
        let pinnedImage = try store.addImageData(Data([1, 1, 1, 1]), fileExtension: "png")
        try store.setPinned(pinnedImage.id, true)
        clock.advance(by: 1)
        let oldImage = try store.addImageData(Data([2, 2, 2, 2]), fileExtension: "png")
        clock.advance(by: 1)
        let newImage = try store.addImageData(Data([3, 3, 3, 3]), fileExtension: "png")

        let ids = store.items.map(\.id)
        #expect(ids.contains(pinnedImage.id))
        #expect(ids.contains(newImage.id))
        #expect(!ids.contains(oldImage.id))
        #expect(!FileManager.default.fileExists(
            atPath: oldImage.resolvedImageURL(baseDirectory: store.storageDirectory).path
        ))
        #expect(store.items.filter { !$0.isPinned }.count <= 3)

        let reloaded = try ClipStore(storageDirectory: store.storageDirectory, now: clock.now)
        #expect(reloaded.items.map(\.id) == store.items.map(\.id))
    }

    @Test("evicted image files are deleted only after the metadata save succeeds")
    func evictionWaitsForSuccessfulSave() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 5_500))
        let store = try ClipStore(storageDirectory: temporaryDirectory(), now: clock.now, maxUnpinnedClips: 1)
        let old = try store.addImageData(Data([4, 4, 4, 4]), fileExtension: "png")
        let oldURL = old.resolvedImageURL(baseDirectory: store.storageDirectory)
        let metadataURL = store.storageDirectory.appendingPathComponent("clips.json")
        try FileManager.default.removeItem(at: metadataURL)
        try FileManager.default.createDirectory(at: metadataURL, withIntermediateDirectories: true)

        clock.advance(by: 1)
        #expect(throws: (any Error).self) { try store.addText("new") }

        #expect(FileManager.default.fileExists(atPath: oldURL.path), "clips.json on disk still lists the old image")
        #expect(store.items.map(\.id) == [old.id], "a failed save leaves memory as it was")
    }

    @Test("defaults cap history at 500 unpinned clips and 500 MB of images")
    func historyCapDefaults() {
        #expect(ClipStore.defaultMaxUnpinnedClips == 500)
        #expect(ClipStore.defaultMaxImageBytes == 500 * 1024 * 1024)
    }

    @Test("a failed file delete leaves memory and disk metadata in agreement")
    func failedFileDeleteLeavesStoreConsistent() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 6_000))
        let fileManager = FailingRemoveFileManager()
        let store = try ClipStore(storageDirectory: temporaryDirectory(), now: clock.now, fileManager: fileManager)
        let image = try store.addImageData(Data([9, 9, 9, 9]), fileExtension: "png")

        fileManager.failRemoves = true
        #expect(throws: (any Error).self) { try store.delete(image.id) }
        #expect(store.items.map(\.id) == [image.id])

        clock.advance(by: (8 * 24 * 60 * 60) + 1)
        #expect(throws: (any Error).self) { try store.cleanupExpiredClips() }
        #expect(store.items.map(\.id) == [image.id])
        let reloaded = try ClipStore(storageDirectory: store.storageDirectory, now: clock.now)
        #expect(reloaded.items.map(\.id) == [image.id])

        fileManager.failRemoves = false
        try store.cleanupExpiredClips()
        #expect(store.items.isEmpty)
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

private final class FailingRemoveFileManager: FileManager, @unchecked Sendable {
    var failRemoves = false

    override func removeItem(at URL: URL) throws {
        if failRemoves {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.removeItem(at: URL)
    }
}
