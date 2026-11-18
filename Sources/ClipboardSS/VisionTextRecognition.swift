import CoreGraphics
import Vision

/// Text recognition for screen text and screenshots.
///
/// Always `.fast`. The first `.accurate` request in a process compiles a Neural Engine
/// model (ANECompilerService). On macOS 27 that takes 30–90 seconds, every other
/// recognition request in the process waits behind it, and it fails (E5RT error 13)
/// when it overlaps another request, so nothing is cached and the next launch pays
/// again. Measured on 2026-11-16, the screen-text shortcut took 49 seconds to open
/// because of it. `.fast` needs no compile and reads a Retina display in well under
/// half a second.
enum VisionTextRecognition {
    static func makeRequest() -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        return request
    }

    /// Synchronous — never call this on the main thread.
    static func perform(on image: CGImage) throws -> VNRecognizeTextRequest {
        let request = makeRequest()
        try VNImageRequestHandler(cgImage: image).perform([request])
        return request
    }
}
