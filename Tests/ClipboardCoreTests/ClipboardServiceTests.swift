import Foundation
import Testing
import CryptoKit
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

    @Test("monitor skips a pasteboard change the app marked as its own")
    func monitorSkipsIgnoredChange() throws {
        let pasteboard = FakePasteboard()
        let store = try ClipStore(storageDirectory: temporaryDirectory())
        let monitor = ClipboardMonitor(pasteboard: pasteboard, store: store)

        pasteboard.changeCount = 1
        pasteboard.snapshot = ClipboardSnapshot(text: "snippet", imageData: nil)
        monitor.ignoreCurrentChange()
        try monitor.poll()

        #expect(store.items.isEmpty)

        pasteboard.changeCount = 2
        pasteboard.snapshot = ClipboardSnapshot(text: "user copy", imageData: nil)
        try monitor.poll()

        #expect(store.items.map(\.text) == ["user copy"])
    }

    @Test("monitor never stores a concealed or transient pasteboard item")
    func testPollSkipsSensitiveSnapshot() throws {
        let pasteboard = FakePasteboard()
        let store = try ClipStore(storageDirectory: temporaryDirectory())
        let monitor = ClipboardMonitor(pasteboard: pasteboard, store: store)

        pasteboard.changeCount = 1
        pasteboard.snapshot = ClipboardSnapshot(text: "hunter2", imageData: nil, isSensitive: true)
        try monitor.poll()
        try monitor.poll()

        #expect(store.items.isEmpty)
    }

    @Test("monitor captures the next normal copy after a sensitive one")
    func testPollCapturesNextNormalCopyAfterSensitiveOne() throws {
        let pasteboard = FakePasteboard()
        let store = try ClipStore(storageDirectory: temporaryDirectory())
        let monitor = ClipboardMonitor(pasteboard: pasteboard, store: store)

        pasteboard.changeCount = 1
        pasteboard.snapshot = ClipboardSnapshot(text: "hunter2", imageData: Data([1, 2, 3]), isSensitive: true)
        try monitor.poll()

        pasteboard.changeCount = 2
        pasteboard.snapshot = ClipboardSnapshot(text: "normal copy", imageData: nil)
        try monitor.poll()
        try monitor.poll()

        #expect(store.items.map(\.text) == ["normal copy"])
    }

    @Test("a capture that fails to save is retried once for the same change, then dropped")
    func pollFailureIsRetriedOnce() throws {
        let pasteboard = FakePasteboard()
        let store = try ClipStore(storageDirectory: temporaryDirectory())
        let monitor = ClipboardMonitor(pasteboard: pasteboard, store: store)
        let metadataURL = store.storageDirectory.appendingPathComponent("clips.json")

        // A directory where clips.json belongs makes every save fail.
        pasteboard.changeCount = 1
        pasteboard.snapshot = ClipboardSnapshot(text: "one", imageData: nil)
        try FileManager.default.createDirectory(at: metadataURL, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try monitor.poll() }
        try FileManager.default.removeItem(at: metadataURL)

        let retried = try monitor.poll()
        #expect(retried?.text == "one", "the failed change must be captured on the next tick")
        #expect(try monitor.poll() == nil)

        // Two failures for the same change: the second is final.
        pasteboard.changeCount = 2
        pasteboard.snapshot = ClipboardSnapshot(text: "two", imageData: nil)
        try FileManager.default.removeItem(at: metadataURL)
        try FileManager.default.createDirectory(at: metadataURL, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try monitor.poll() }
        #expect(throws: (any Error).self) { try monitor.poll() }
        try FileManager.default.removeItem(at: metadataURL)
        #expect(try monitor.poll() == nil)
    }

    @Test("PairedDevice persists optional host and legacy records decode")
    func pairedDeviceHostRoundTrip() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(#"[{"id":"\#(UUID().uuidString)","name":"Old"}]"#.utf8).write(to: tmp)

        let store = try PairedDeviceStore(storageURL: tmp, keyStorage: InMemoryPairKeyStorage())
        #expect(await store.devices.first?.host == nil)

        let dev = PairedDevice(id: UUID(), name: "Mac", host: "192.168.0.4")
        try await store.addDevice(dev, key: SymmetricKey(size: .bits256))
        try await store.updateHost(dev.id, host: "192.168.0.42")

        let reopened = try PairedDeviceStore(storageURL: tmp, keyStorage: InMemoryPairKeyStorage())
        #expect(await reopened.devices.contains { $0.host == "192.168.0.42" })
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

private final class InMemoryPairKeyStorage: PairKeyStorage, @unchecked Sendable {
    private var keys: [UUID: SymmetricKey] = [:]

    func storeKey(_ key: SymmetricKey, for deviceId: UUID) throws {
        keys[deviceId] = key
    }

    func getKey(for deviceId: UUID) throws -> SymmetricKey? {
        keys[deviceId]
    }

    func deleteKey(for deviceId: UUID) throws {
        keys[deviceId] = nil
    }
}
