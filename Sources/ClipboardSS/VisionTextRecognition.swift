import CoreGraphics
import CoreText
import Foundation
import Vision

/// Picks the Vision recognition level. The first `.accurate` request compiles a Neural
/// Engine model; on macOS 27 that has taken over a minute and can still fail (E5RT
/// error 13, surfacing as CRImageReaderError error 1). Callers get `.fast` until a
/// background warm-up proves `.accurate` is loaded, so OCR never waits on the compile.
final class RecognitionLevelGate: @unchecked Sendable {
    private enum State { case cold, warming, ready, unavailable }

    private let lock = NSLock()
    private var state = State.cold

    var level: VNRequestTextRecognitionLevel {
        lock.withLock { state == .ready ? .accurate : .fast }
    }

    /// True for the single caller that should run the warm-up.
    func claimWarmUp() -> Bool {
        lock.withLock {
            guard state == .cold else { return false }
            state = .warming
            return true
        }
    }

    func warmUpFinished(succeeded: Bool) {
        lock.withLock { state = succeeded ? .ready : .unavailable }
    }

    func accurateFailed() {
        lock.withLock { state = .unavailable }
    }
}

enum VisionTextRecognition {
    static let gate = RecognitionLevelGate()

    /// Loads the `.accurate` model off the main thread so the first screen-text or
    /// screenshot OCR doesn't pay for it. Safe to call more than once.
    static func warmUp() {
        guard gate.claimWarmUp() else { return }
        Task.detached(priority: .utility) {
            let succeeded = sampleImage().flatMap { try? recognize($0, level: .accurate) } != nil
            gate.warmUpFinished(succeeded: succeeded)
        }
    }

    /// Synchronous and can be slow — never call this on the main thread.
    static func perform(on image: CGImage) throws -> VNRecognizeTextRequest {
        if gate.level == .accurate {
            do {
                return try recognize(image, level: .accurate)
            } catch {
                gate.accurateFailed()
            }
        }
        return try recognize(image, level: .fast)
    }

    private static func recognize(_ image: CGImage, level: VNRequestTextRecognitionLevel) throws -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        return request
    }

    /// A small image containing real text: the recognizer model only loads once
    /// the detector finds something to read.
    private static func sampleImage() -> CGImage? {
        let width = 480
        let height = 80
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            return nil
        }

        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 0, alpha: 1))

        let text = NSAttributedString(string: "Clipboard SS 2026", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 40, nil),
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true
        ])
        context.textPosition = CGPoint(x: 16, y: 22)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        return context.makeImage()
    }
}
