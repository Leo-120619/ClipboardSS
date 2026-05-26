import ClipboardCore
import Foundation
import Testing
@testable import ClipboardSS

@MainActor
@Suite("App model paste workflow")
struct AppModelPasteTests {
    @Test("single click copies then requests a keep-open paste")
    func singleClickCopiesThenRequestsKeepOpenPaste() throws {
        let fixture = try AppModelFixture()
        let clip = try fixture.store.addText("hello")
        var requests: [PasteRequest] = []
        fixture.model.onPasteRequested = { requests.append($0) }

        fixture.model.handleClipSingleClick(clip)

        #expect(fixture.pasteboard.lastText == "hello")
        #expect(requests == [.keepClipboardOpenAfterPaste])
    }

    @Test("double click copies then requests a close-after-paste")
    func doubleClickCopiesThenRequestsCloseAfterPaste() throws {
        let fixture = try AppModelFixture()
        let clip = try fixture.store.addText("close")
        var requests: [PasteRequest] = []
        fixture.model.onPasteRequested = { requests.append($0) }

        fixture.model.handleClipDoubleClick(clip)

        #expect(fixture.pasteboard.lastText == "close")
        #expect(requests == [.closeClipboardAfterPaste])
    }

    @Test("paste and close copies the clip then requests a closing paste")
    func pasteAndCloseCopiesThenRequestsPaste() throws {
        let fixture = try AppModelFixture()
        let clip = try fixture.store.addText("hello")
        var requests: [PasteRequest] = []
        fixture.model.onPasteRequested = { requests.append($0) }

        fixture.model.paste(clip, mode: .closeClipboardAfterPaste)

        #expect(fixture.pasteboard.lastText == "hello")
        #expect(requests == [.closeClipboardAfterPaste])
    }

    @Test("paste and keep open copies the clip then requests a keep-open paste")
    func pasteAndKeepOpenCopiesThenRequestsPaste() throws {
        let fixture = try AppModelFixture()
        let clip = try fixture.store.addText("again")
        var requests: [PasteRequest] = []
        fixture.model.onPasteRequested = { requests.append($0) }

        fixture.model.paste(clip, mode: .keepClipboardOpenAfterPaste)

        #expect(fixture.pasteboard.lastText == "again")
        #expect(requests == [.keepClipboardOpenAfterPaste])
    }
}

@MainActor
private struct AppModelFixture {
    let store: ClipStore
    let pasteboard: FakePasteboard
    let model: AppModel

    init() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = try ClipStore(storageDirectory: directory)
        let pasteboard = FakePasteboard()
        self.store = store
        self.pasteboard = pasteboard
        self.model = AppModel(
            store: store,
            writer: ClipboardWriter(pasteboard: pasteboard, store: store),
            screenshotCaptureService: ScreenshotCaptureService(),
            ocrService: OCRService(),
            pasteboard: pasteboard
        )
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
