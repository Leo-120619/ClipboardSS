import AppKit
import ClipboardCore
import Foundation
import Testing
@testable import ClipboardSS

@MainActor
@Suite("App model broadcast")
struct AppModelBroadcastTests {
    @Test("deleting the top clip does not broadcast the next one")
    func deletingTopClipDoesNotBroadcast() throws {
        let fixture = try BroadcastFixture()
        try fixture.store.addText("older")
        let top = try fixture.store.addText("newer")
        fixture.model.refresh()

        fixture.model.delete(top)

        #expect(fixture.broadcasts.isEmpty)
    }

    @Test("expiring the top clip does not broadcast the next one")
    func expiringTopClipDoesNotBroadcast() throws {
        let fixture = try BroadcastFixture()
        let pinned = try fixture.store.addText("pinned")
        try fixture.store.setPinned(pinned.id, true)
        fixture.clock.now = fixture.clock.now.addingTimeInterval(60)
        try fixture.store.addText("expiring")
        fixture.model.refresh()

        fixture.clock.now = fixture.clock.now.addingTimeInterval(8 * 24 * 60 * 60)
        try fixture.model.cleanupExpiredClips()
        fixture.tick()

        #expect(fixture.store.items.map(\.text) == ["pinned"])
        #expect(fixture.broadcasts.isEmpty)
    }

    @Test("a clip received from a peer is not sent back out")
    func receivedClipIsNotRebroadcast() throws {
        let fixture = try BroadcastFixture()
        let payload = ClipPayload(
            id: UUID(), type: .text, createdAt: Date(), text: "from phone",
            previewText: "from phone", contentHash: "ignored", sourceDeviceName: "Phone"
        )

        _ = try fixture.receiver.receive(payload)
        fixture.tick()

        #expect(fixture.store.items.map(\.text) == ["from phone"])
        #expect(fixture.broadcasts.isEmpty)
    }

    @Test("copying an image from history does not store a duplicate")
    func copyingImageFromHistoryDoesNotCreateDuplicate() throws {
        let fixture = try BroadcastFixture(systemPasteboard: true)
        let clip = try fixture.store.addImageData(Self.png, fileExtension: "png")
        try fixture.store.addText("newer")
        fixture.tick()

        fixture.model.copy(clip)
        fixture.tick()

        #expect(fixture.store.items.count == 2)
        #expect(fixture.store.items.first?.id == clip.id)
        #expect(fixture.broadcasts.isEmpty)
    }

    @Test("an image received from a peer does not store a duplicate")
    func receivedImageDoesNotCreateDuplicate() throws {
        let fixture = try BroadcastFixture(systemPasteboard: true)
        let payload = ClipPayload(
            id: UUID(), type: .image, createdAt: Date(), text: nil,
            imageBase64: Self.png.base64EncodedString(), imageExtension: "png",
            previewText: "Image", contentHash: "ignored", sourceDeviceName: "Phone"
        )

        _ = try fixture.receiver.receive(payload)
        fixture.tick()

        #expect(fixture.store.items.count == 1)
        #expect(fixture.broadcasts.isEmpty)
    }

    @Test("a genuine local copy is broadcast exactly once")
    func localCopyIsBroadcastOnce() throws {
        let fixture = try BroadcastFixture()
        fixture.fakePasteboard?.simulateUserCopy(text: "typed on mac")

        fixture.tick()
        fixture.tick()

        #expect(fixture.broadcasts.map(\.text) == ["typed on mac"])
    }

    @Test("writing an image puts its original PNG bytes on the pasteboard")
    func writeImageDataKeepsOriginalPNGBytes() {
        let client = SystemPasteboardClient(pasteboard: NSPasteboard(name: .init("ClipboardSSTests-\(UUID().uuidString)")))

        client.clearContents()
        client.writeImageData(Self.png)

        #expect(client.readSnapshot().imageData == Self.png)
    }

    /// A valid 1x1 PNG.
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
}

@MainActor
private final class BroadcastFixture {
    let clock = TestClock()
    let store: ClipStore
    let pasteboard: PasteboardClient
    let fakePasteboard: BroadcastFakePasteboard?
    let monitor: ClipboardMonitor
    let receiver: ClipReceiver
    let model: AppModel
    private(set) var broadcasts: [ClipItem] = []

    init(systemPasteboard: Bool = false) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let clock = self.clock
        store = try ClipStore(storageDirectory: directory, now: { clock.now })
        if systemPasteboard {
            let named = NSPasteboard(name: .init("ClipboardSSTests-\(UUID().uuidString)"))
            pasteboard = SystemPasteboardClient(pasteboard: named)
            fakePasteboard = nil
        } else {
            let fake = BroadcastFakePasteboard()
            pasteboard = fake
            fakePasteboard = fake
        }
        monitor = ClipboardMonitor(pasteboard: pasteboard, store: store)
        receiver = ClipReceiver(store: store, pasteboard: pasteboard, monitor: monitor)
        model = try makeTestAppModel(store: store, pasteboard: pasteboard, clipboardMonitor: monitor)
        // Baseline: whatever is on the pasteboard before the test is not a new copy.
        try monitor.poll()
        model.onClipBroadcast = { [unowned self] clip in broadcasts.append(clip) }
    }

    /// One pass of the app's clipboard poll timer (AppDelegate.pollClipboard).
    func tick() {
        if let clip = try? monitor.poll() {
            model.broadcastCaptured(clip)
        }
        model.refresh()
    }
}

private final class TestClock {
    var now = Date(timeIntervalSince1970: 1_000_000)
}

private final class BroadcastFakePasteboard: PasteboardClient {
    private var changeCount = 0
    private var snapshot = ClipboardSnapshot(text: nil, imageData: nil)

    func simulateUserCopy(text: String) {
        changeCount += 1
        snapshot = ClipboardSnapshot(text: text, imageData: nil)
    }

    func currentChangeCount() -> Int { changeCount }
    func readSnapshot() -> ClipboardSnapshot { snapshot }

    func clearContents() {
        changeCount += 1
        snapshot = ClipboardSnapshot(text: nil, imageData: nil)
    }

    func writeText(_ text: String) {
        snapshot.text = text
    }

    func writeImageData(_ data: Data) {
        snapshot.imageData = data
    }
}
