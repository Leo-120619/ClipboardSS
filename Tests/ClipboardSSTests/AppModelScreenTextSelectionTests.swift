import ClipboardCore
import Foundation
import Testing
@testable import ClipboardSS

@MainActor
@Suite("App model screen text selection")
struct AppModelScreenTextSelectionTests {
    @Test("repeated shortcut events do not start overlapping screen captures")
    func repeatedShortcutEventsDoNotOverlapCapture() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ClipStore(storageDirectory: directory)
        let pasteboard = ScreenTextFakePasteboard()
        let captureService = SuspendedScreenTextCaptureService()
        let model = try makeTestAppModel(
            store: store,
            pasteboard: pasteboard,
            screenTextCaptureService: captureService
        )

        model.startScreenTextSelection()
        model.startScreenTextSelection()
        while captureService.callCount == 0 {
            await Task.yield()
        }

        #expect(captureService.callCount == 1)

        captureService.finish()
        while model.isSelectingScreenText {
            await Task.yield()
        }
    }
}

private final class ScreenTextFakePasteboard: PasteboardClient {
    func currentChangeCount() -> Int { 0 }
    func readSnapshot() -> ClipboardSnapshot { ClipboardSnapshot(text: nil, imageData: nil) }
    func clearContents() {}
    func writeText(_ text: String) {}
    func writeImageData(_ data: Data) {}
}

@MainActor
private final class SuspendedScreenTextCaptureService: ScreenTextCapturing {
    private(set) var callCount = 0
    private var continuation: CheckedContinuation<ScreenTextCapture, any Error>?

    func captureAllDisplays() async throws -> ScreenTextCapture {
        callCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func finish() {
        continuation?.resume(returning: ScreenTextCapture(blocks: [], snapshots: [:]))
        continuation = nil
    }
}
