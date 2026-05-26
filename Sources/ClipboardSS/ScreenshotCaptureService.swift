import Foundation

@MainActor
final class ScreenshotCaptureService {
    enum CaptureError: LocalizedError {
        case cancelled
        case screenRecordingDenied

        var errorDescription: String? {
            switch self {
            case .cancelled:
                "Screenshot capture was cancelled."
            case .screenRecordingDenied:
                AppPermission.screenRecording.deniedMessage
            }
        }
    }

    func captureRegion() async throws -> URL {
        guard AppPermission.screenRecording.isGranted else {
            throw CaptureError.screenRecordingDenied
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardSS-\(UUID().uuidString).png")

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-i", "-x", url.path]
            process.terminationHandler = { process in
                if process.terminationStatus == 0, FileManager.default.fileExists(atPath: url.path) {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: CaptureError.cancelled)
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
