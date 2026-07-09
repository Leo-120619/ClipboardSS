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

    @Test("send targets union mDNS peers with paired hosts, de-duped by id")
    func sendTargetUnion() {
        let id1 = UUID()
        let id2 = UUID()
        let mdns = [Peer(id: id1, name: "Phone", host: "192.168.0.9", port: 51888)]
        let paired = [
            PairedDevice(id: id1, name: "Phone", host: "192.168.0.99"),
            PairedDevice(id: id2, name: "Tablet", host: "192.168.0.20"),
        ]

        let targets = AppModel.composeSendTargets(mdnsPeers: mdns, pairedDevices: paired)

        #expect(targets.count == 2)
        #expect(targets.first { $0.id == id1 }?.host == "192.168.0.9")
        #expect(targets.first { $0.id == id2 }?.host == "192.168.0.20")
    }

    @Test("join candidates try mDNS first then swept peers")
    func joinCandidateUnion() {
        let id1 = UUID()
        let id2 = UUID()
        let mdns = [Peer(id: id1, name: "Wrong", host: "192.168.0.10", port: 51888)]
        let swept = [
            Peer(id: id2, name: "Mac", host: "192.168.0.20", port: 51888),
            Peer(id: id1, name: "Wrong Duplicate", host: "192.168.0.11", port: 51888),
        ]

        let targets = AppModel.composeJoinCandidates(mdnsPeers: mdns, sweptPeers: swept)

        #expect(targets.map(\.id) == [id1, id2])
        #expect(targets[0].host == "192.168.0.10")
        #expect(targets[1].host == "192.168.0.20")
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
        self.model = try makeTestAppModel(store: store, pasteboard: pasteboard)
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
