import AppKit
import ApplicationServices
import ClipboardCore
import CoreGraphics
import ScreenCaptureKit
import Vision

struct ScreenTextCapture {
    let blocks: [ScreenTextBlock]
    let snapshots: [UInt32: CGImage]
}

@MainActor
protocol ScreenTextCapturing: AnyObject {
    func captureAllDisplays() async throws -> ScreenTextCapture
}

@MainActor
final class ScreenTextCaptureService: ScreenTextCapturing {
    enum ScreenTextCaptureError: LocalizedError {
        case noTextDetected
        case screenRecordingDenied

        var errorDescription: String? {
            switch self {
            case .noTextDetected:
                "No selectable screen text was detected."
            case .screenRecordingDenied:
                AppPermission.screenRecording.deniedMessage
            }
        }
    }

    func captureAllDisplays() async throws -> ScreenTextCapture {
        guard AppPermission.screenRecording.isGranted else {
            throw ScreenTextCaptureError.screenRecordingDenied
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let excludedApps = content.applications.filter { app in
            app.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        let screensByDisplayID: [UInt32: NSScreen] = Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { screen in
            guard let displayID = screen.displayID else {
                return nil
            }
            return (displayID, screen)
        })

        var blocks: [ScreenTextBlock] = []
        var snapshots: [UInt32: CGImage] = [:]

        for display in content.displays {
            guard let screen = screensByDisplayID[display.displayID] else {
                continue
            }

            let filter = SCContentFilter(
                display: display,
                excludingApplications: excludedApps,
                exceptingWindows: []
            )
            let configuration = SCStreamConfiguration()
            configuration.width = display.width
            configuration.height = display.height
            configuration.showsCursor = false

            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            snapshots[display.displayID] = image
            blocks.append(contentsOf: try recognizeText(in: image, displayID: display.displayID, screenFrame: screen.frame))
        }

        let deduplicated = ScreenTextSelectionState.deduplicated(blocks)
        guard !deduplicated.isEmpty else {
            throw ScreenTextCaptureError.noTextDetected
        }
        return ScreenTextCapture(blocks: deduplicated, snapshots: snapshots)
    }

    private func recognizeText(in image: CGImage, displayID: UInt32, screenFrame: CGRect) throws -> [ScreenTextBlock] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: image)
        try handler.perform([request])

        return request.results?.flatMap { observation -> [ScreenTextBlock] in
            guard let candidate = observation.topCandidates(1).first else {
                return []
            }

            let fullText = candidate.string
            var blocks: [ScreenTextBlock] = []

            let words = fullText.split(whereSeparator: \.isWhitespace)
            var searchStartIndex = fullText.startIndex

            for wordSubstring in words {
                let word = String(wordSubstring)
                guard let wordRange = fullText.range(of: word, range: searchStartIndex..<fullText.endIndex) else {
                    continue
                }
                searchStartIndex = wordRange.upperBound

                let boundingBox: CGRect
                if let box = try? candidate.boundingBox(for: wordRange) {
                    boundingBox = box.boundingBox
                } else {
                    boundingBox = observation.boundingBox
                }

                blocks.append(ScreenTextBlock(
                    id: UUID().uuidString,
                    text: word,
                    bounds: Self.screenBounds(for: boundingBox, in: screenFrame),
                    displayID: displayID,
                    source: .ocr
                ))
            }

            return blocks
        } ?? []
    }

    private static func screenBounds(for normalizedBounds: CGRect, in screenFrame: CGRect) -> CGRect {
        CGRect(
            x: screenFrame.minX + normalizedBounds.minX * screenFrame.width,
            y: screenFrame.minY + normalizedBounds.minY * screenFrame.height,
            width: normalizedBounds.width * screenFrame.width,
            height: normalizedBounds.height * screenFrame.height
        )
    }
}

extension NSScreen {
    var displayID: UInt32? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
