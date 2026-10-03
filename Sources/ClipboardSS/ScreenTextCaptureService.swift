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
final class ScreenTextCaptureService {
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
        // ScreenTextSelectionState orders text top-to-bottom by ascending minY, so blocks are
        // stored in top-left-origin global coordinates rather than Cocoa's bottom-left ones.
        let primaryScreenMaxY = NSScreen.screens.first?.frame.maxY ?? 0

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
            // SCDisplay reports its size in points; capture at native pixel resolution so
            // Retina text is not downsampled before OCR.
            let scale = screen.backingScaleFactor
            configuration.width = Int((CGFloat(display.width) * scale).rounded())
            configuration.height = Int((CGFloat(display.height) * scale).rounded())
            configuration.showsCursor = false

            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            snapshots[display.displayID] = image
            blocks.append(contentsOf: try recognizeText(
                in: image,
                displayID: display.displayID,
                screenRect: screen.frame.topLeftOrigin(primaryScreenMaxY: primaryScreenMaxY)
            ))
        }

        let deduplicated = ScreenTextSelectionState.deduplicated(blocks)
        guard !deduplicated.isEmpty else {
            throw ScreenTextCaptureError.noTextDetected
        }
        return ScreenTextCapture(blocks: deduplicated, snapshots: snapshots)
    }

    private func recognizeText(in image: CGImage, displayID: UInt32, screenRect: CGRect) throws -> [ScreenTextBlock] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: image)
        try handler.perform([request])

        return request.results?.enumerated().flatMap { observationIndex, observation -> [ScreenTextBlock] in
            guard let candidate = observation.topCandidates(1).first else {
                return []
            }

            let fullText = candidate.string
            let lineBox = observation.boundingBox
            // Each observation is one recognized line; tag its words so they are grouped and
            // ordered together instead of being re-clustered by position.
            let lineID = "\(displayID):ocr:\(observationIndex)"
            let totalCharacters = max(fullText.count, 1)
            var blocks: [ScreenTextBlock] = []

            var searchStartIndex = fullText.startIndex
            for wordSubstring in fullText.split(whereSeparator: \.isWhitespace) {
                let word = String(wordSubstring)
                guard let wordRange = fullText.range(of: word, range: searchStartIndex..<fullText.endIndex) else {
                    continue
                }
                searchStartIndex = wordRange.upperBound

                let estimatedBox = Self.estimatedWordBox(
                    for: wordRange,
                    in: fullText,
                    totalCharacters: totalCharacters,
                    lineBox: lineBox
                )
                var boundingBox = estimatedBox
                if let box = try? candidate.boundingBox(for: wordRange)?.boundingBox,
                   !box.isEmpty,
                   !Self.coversWholeLine(box, lineBox: lineBox, wordBox: estimatedBox) {
                    boundingBox = box
                }

                blocks.append(ScreenTextBlock(
                    id: UUID().uuidString,
                    text: word,
                    bounds: Self.screenBounds(for: boundingBox, in: screenRect),
                    displayID: displayID,
                    source: .ocr,
                    lineID: lineID
                ))
            }

            return blocks
        } ?? []
    }

    /// Approximates a word's box by its character offset within the line. Used when Vision
    /// cannot (or does not meaningfully) report a per-word box.
    private static func estimatedWordBox(
        for range: Range<String.Index>,
        in text: String,
        totalCharacters: Int,
        lineBox: CGRect
    ) -> CGRect {
        let startOffset = text.distance(from: text.startIndex, to: range.lowerBound)
        let length = text.distance(from: range.lowerBound, to: range.upperBound)
        let charWidth = lineBox.width / CGFloat(totalCharacters)
        return CGRect(
            x: lineBox.minX + CGFloat(startOffset) * charWidth,
            y: lineBox.minY,
            width: CGFloat(length) * charWidth,
            height: lineBox.height
        )
    }

    /// Vision sometimes returns the whole line's box for a sub-range. Treat that as missing so
    /// words on the same line keep distinct, correctly ordered positions.
    private static func coversWholeLine(_ box: CGRect, lineBox: CGRect, wordBox: CGRect) -> Bool {
        guard wordBox.width < lineBox.width * 0.9 else {
            return false
        }
        return box.width >= lineBox.width * 0.95
    }

    /// Converts Vision's normalized, bottom-left-origin box into top-left-origin global coordinates.
    private static func screenBounds(for normalizedBounds: CGRect, in screenRect: CGRect) -> CGRect {
        CGRect(
            x: screenRect.minX + normalizedBounds.minX * screenRect.width,
            y: screenRect.minY + (1 - normalizedBounds.maxY) * screenRect.height,
            width: normalizedBounds.width * screenRect.width,
            height: normalizedBounds.height * screenRect.height
        )
    }
}

extension NSScreen {
    var displayID: UInt32? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

extension CGRect {
    /// Flips a Cocoa (bottom-left-origin) global rect into top-left-origin global coordinates.
    func topLeftOrigin(primaryScreenMaxY: CGFloat) -> CGRect {
        CGRect(x: minX, y: primaryScreenMaxY - maxY, width: width, height: height)
    }
}
