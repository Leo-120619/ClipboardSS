import Foundation
import Testing
@testable import ClipboardCore

@Suite("Clipboard service")
struct ClipboardServiceTests {
    @Test("writes text clips to the pasteboard")
    func writesTextClips() throws {
        let pasteboard = FakePasteboard()
        let store = try ClipStore(storageDirectory: temporaryDirectory(), now: { Date(timeIntervalSince1970: 5_000) })
        let clip = try store.addText("hello")
        let writer = ClipboardWriter(pasteboard: pasteboard, store: store)

        try writer.copy(clip)

        #expect(pasteboard.clearCount == 1)
        #expect(pasteboard.lastText == "hello")
        #expect(store.items.first?.lastCopiedAt != nil)
    }

    @Test("writes image clips to the pasteboard")
    func writesImageClips() throws {
        let pasteboard = FakePasteboard()
        let store = try ClipStore(storageDirectory: temporaryDirectory(), now: { Date(timeIntervalSince1970: 6_000) })
        let data = Data([1, 2, 3])
        let clip = try store.addImageData(data, fileExtension: "png")
        let writer = ClipboardWriter(pasteboard: pasteboard, store: store)

        try writer.copy(clip)

        #expect(pasteboard.lastImageData == data)
    }

    @Test("monitor stores a text snapshot only when the pasteboard change count advances")
    func monitorStoresNewTextSnapshotOnce() throws {
        let pasteboard = FakePasteboard()
        let store = try ClipStore(storageDirectory: temporaryDirectory())
        let monitor = ClipboardMonitor(pasteboard: pasteboard, store: store)

        pasteboard.changeCount = 1
        pasteboard.snapshot = ClipboardSnapshot(text: "one", imageData: nil)
        try monitor.poll()
        try monitor.poll()

        #expect(store.items.map(\.text) == ["one"])

        pasteboard.changeCount = 2
        pasteboard.snapshot = ClipboardSnapshot(text: "two", imageData: nil)
        try monitor.poll()

        #expect(store.items.map(\.text) == ["two", "one"])
    }
}

private final class FakePasteboard: PasteboardClient {
    var changeCount = 0
    var snapshot = ClipboardSnapshot(text: nil, imageData: nil)
    var clearCount = 0
    var lastText: String?
    var lastImageData: Data?

    func currentChangeCount() -> Int {
        changeCount
    }

    func readSnapshot() -> ClipboardSnapshot {
        snapshot
    }

    func clearContents() {
        clearCount += 1
        lastText = nil
        lastImageData = nil
    }

    func writeText(_ text: String) {
        lastText = text
    }

    func writeImageData(_ data: Data) {
        lastImageData = data
    }
}
