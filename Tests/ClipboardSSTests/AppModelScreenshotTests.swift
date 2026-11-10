import AppKit
import ClipboardCore
import Foundation
import Testing
@testable import ClipboardSS

@MainActor
@Suite("App model screenshot capture")
struct AppModelScreenshotTests {
    @Test("the temporary screenshot PNG is deleted once it is imported")
    func screenshotTempFileIsRemoved() async throws {
        let (model, store, capture) = try makeModel()

        model.captureScreenshot()
        try await waitUntil { capture.callCount == 1 }
        let tempURL = try capture.finishWithPNG()
        try await waitUntil { !model.isCapturingScreenshot }

        #expect(!FileManager.default.fileExists(atPath: tempURL.path), "temp PNG must not outlive the import")
        #expect(store.items.first?.previewText == "Screenshot")
        if let review = model.screenshotReview {
            #expect(FileManager.default.fileExists(atPath: review.imageURL.path), "review shows the stored copy")
        }
    }

    @Test("a second capture request while one is running is ignored")
    func overlappingCaptureIsIgnored() async throws {
        let (model, _, capture) = try makeModel()

        model.captureScreenshot()
        model.captureScreenshot()
        try await waitUntil { capture.callCount >= 1 }
        await Task.yield()

        #expect(capture.callCount == 1)
        capture.cancel()
        try await waitUntil { !model.isCapturingScreenshot }
    }

    private func makeModel() throws -> (AppModel, ClipStore, SuspendedScreenshotCaptureService) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = try ClipStore(storageDirectory: directory)
        let capture = SuspendedScreenshotCaptureService()
        let model = try makeTestAppModel(
            store: store,
            pasteboard: ScreenshotFakePasteboard(),
            screenshotCaptureService: capture
        )
        return (model, store, capture)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            if Date() >= deadline {
                Issue.record("Timed out waiting for condition")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private final class ScreenshotFakePasteboard: PasteboardClient {
    func currentChangeCount() -> Int { 0 }
    func readSnapshot() -> ClipboardSnapshot { ClipboardSnapshot(text: nil, imageData: nil) }
    func clearContents() {}
    func writeText(_ text: String) {}
    func writeImageData(_ data: Data) {}
}

@MainActor
private final class SuspendedScreenshotCaptureService: ScreenshotCapturing {
    private(set) var callCount = 0
    private var continuation: CheckedContinuation<URL, any Error>?

    func captureRegion() async throws -> URL {
        callCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    /// Writes a small PNG to the temp directory, as `screencapture` would, and returns it.
    func finishWithPNG() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardSS-test-\(UUID().uuidString).png")
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: url)
        continuation?.resume(returning: url)
        continuation = nil
        return url
    }

    func cancel() {
        continuation?.resume(throwing: ScreenshotCaptureService.CaptureError.cancelled)
        continuation = nil
    }
}
