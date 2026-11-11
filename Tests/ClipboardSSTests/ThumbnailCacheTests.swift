import AppKit
import Testing
@testable import ClipboardSS

@MainActor
@Suite("Thumbnail cache")
struct ThumbnailCacheTests {
    @Test("an image costs its decoded pixel bytes")
    func costIsDecodedPixelBytes() throws {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 10, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let image = NSImage(size: NSSize(width: 20, height: 5))
        image.addRepresentation(bitmap)

        #expect(ThumbnailCache.decodedByteCost(of: image) == 40 * 10 * 4)
    }
}
