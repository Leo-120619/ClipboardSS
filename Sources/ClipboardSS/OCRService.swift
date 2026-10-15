import AppKit
import ClipboardCore
import Vision

@MainActor
final class OCRService {
    enum OCRError: Error {
        case imageLoadFailed
        case cgImageFailed
    }

    func recognizeText(in imageURL: URL) async throws -> [OCRTextBlock] {
        try await Task.detached(priority: .userInitiated) {
            guard let image = NSImage(contentsOf: imageURL) else {
                throw OCRError.imageLoadFailed
            }
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw OCRError.cgImageFailed
            }

            let request = try VisionTextRecognition.perform(on: cgImage)

            return request.results?.compactMap { observation in
                guard let text = observation.topCandidates(1).first?.string, !text.isEmpty else {
                    return nil
                }

                return OCRTextBlock(id: UUID().uuidString, text: text)
            } ?? []
        }
        .value
    }
}
