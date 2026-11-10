import ClipboardCore
import Foundation
import Testing
@testable import ClipboardSS

@MainActor
@Suite("App model receive prompt")
struct AppModelReceiveTests {
    @Test("the folder prompt moves the file it was opened for, even if transfers change while it is up")
    func receivePromptUsesTransferIdNotIndex() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let landing = root.appendingPathComponent("Landing", isDirectory: true)
        let chosen = root.appendingPathComponent("Chosen", isDirectory: true)
        try FileManager.default.createDirectory(at: landing, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileA = landing.appendingPathComponent("a.txt")
        let fileB = landing.appendingPathComponent("b.txt")
        try Data("A".utf8).write(to: fileA)
        try Data("B".utf8).write(to: fileB)
        // A file with A's name already sits in the chosen folder.
        try Data("existing".utf8).write(to: chosen.appendingPathComponent("a.txt"))

        let store = try ClipStore(storageDirectory: root.appendingPathComponent("Store", isDirectory: true))
        let model = try makeTestAppModel(store: store, pasteboard: ReceiveFakePasteboard())
        model.receiveModeProvider = { .askEveryTime }
        var promptCount = 0
        model.chooseReceiveDirectory = {
            promptCount += 1
            // The panel runs a modal loop: another transfer starts and finishes meanwhile.
            model.handleReceiveEvent(.started(transferId: "b", fileName: "b.txt", chunkCount: 1))
            model.handleReceiveEvent(.completed(transferId: "b", url: fileB))
            return chosen
        }
        var notified: [URL] = []
        model.onReceivedFileCompleted = { notified.append($0) }

        model.handleReceiveEvent(.started(transferId: "a", fileName: "a.txt", chunkCount: 1))
        model.handleReceiveEvent(.completed(transferId: "a", url: fileA))

        let transferA = try #require(model.transfers.first { $0.key == "a" })
        let transferB = try #require(model.transfers.first { $0.key == "b" })
        #expect(promptCount == 1, "files finishing while the prompt is up reuse its answer")
        #expect(transferA.destinationURL == chosen.appendingPathComponent("a (1).txt"))
        #expect(transferB.destinationURL == chosen.appendingPathComponent("b.txt"))
        #expect(try Data(contentsOf: chosen.appendingPathComponent("a (1).txt")) == Data("A".utf8))
        #expect(try Data(contentsOf: chosen.appendingPathComponent("a.txt")) == Data("existing".utf8))
        #expect(try Data(contentsOf: chosen.appendingPathComponent("b.txt")) == Data("B".utf8))
        #expect(Set(notified) == [chosen.appendingPathComponent("a (1).txt"), chosen.appendingPathComponent("b.txt")])
    }
}

private final class ReceiveFakePasteboard: PasteboardClient {
    func currentChangeCount() -> Int { 0 }
    func readSnapshot() -> ClipboardSnapshot { ClipboardSnapshot(text: nil, imageData: nil) }
    func clearContents() {}
    func writeText(_ text: String) {}
    func writeImageData(_ data: Data) {}
}
