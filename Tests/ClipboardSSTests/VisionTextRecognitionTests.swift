import Testing
import Vision
@testable import ClipboardSS

@Suite("Vision text recognition")
struct VisionTextRecognitionTests {
    /// `.accurate` compiles a Neural Engine model on first use, which has blocked the
    /// screen-text shortcut for most of a minute. See `VisionTextRecognition`.
    @Test("requests use the fast recognizer, which needs no model compile")
    func requestsUseFastRecognition() {
        let request = VisionTextRecognition.makeRequest()

        #expect(request.recognitionLevel == .fast)
        #expect(request.usesLanguageCorrection == false)
    }
}
