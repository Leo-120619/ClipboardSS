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

    @Test("a large image is cached as a downsampled preview")
    func largeImageIsDownsampled() throws {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2000, pixelsHigh: 1000, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("thumbnail-\(UUID().uuidString).png")
        try png.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let image = try #require(ThumbnailCache(countLimit: 1).image(at: url))
        #expect(image.size == NSSize(width: 1024, height: 512))
        #expect(ThumbnailCache.decodedByteCost(of: image) == 1024 * 512 * 4)
    }
}
