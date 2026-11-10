import Foundation
import ImageIO

/// Decode-validates image bytes received from a peer before they are stored or put on the pasteboard.
public enum ImageDataValidator {
    public static func isDecodableImage(_ data: Data) -> Bool {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetCount(source) > 0
        else {
            return false
        }

        // Building a small thumbnail forces an actual decode instead of only parsing the header.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
            kCGImageSourceShouldCache: false,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return false
        }
        return thumbnail.width > 0 && thumbnail.height > 0
    }
}
