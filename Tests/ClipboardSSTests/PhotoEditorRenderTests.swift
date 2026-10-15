import CoreGraphics
import Testing
@testable import ClipboardSS

@Suite("Photo editor rendering")
struct PhotoEditorRenderTests {
    @Test("images drawn into the y-down export context stay upright")
    func imageStaysUpright() throws {
        let size = CGSize(width: 4, height: 4)
        let source = try #require(Self.makeImage(size: size, topIsRed: true))
        let context = try #require(Self.makeContext(size: size))

        // Same setup as renderFinal(): flip to y-down so paths match SwiftUI coordinates.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        PhotoEditorView.drawUpright(source, in: CGRect(origin: .zero, size: size), context: context)

        let output = try #require(context.makeImage())
        // Thresholds allow for color-space conversion noise.
        #expect(try #require(Self.redComponent(of: output, row: 0)) > 200)
        #expect(try #require(Self.redComponent(of: output, row: 3)) < 50)
    }

    private static func makeContext(size: CGSize) -> CGContext? {
        CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    /// Top half red, bottom half blue, as it appears on screen.
    private static func makeImage(size: CGSize, topIsRed: Bool) -> CGImage? {
        guard let context = makeContext(size: size) else { return nil }
        let half = size.height / 2
        // CGContext is y-up: the upper half on screen is y in [half, height].
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: half, width: size.width, height: half))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size.width, height: half))
        return context.makeImage()
    }

    /// Red channel of the first pixel in `row`, where row 0 is the top of the image.
    private static func redComponent(of image: CGImage, row: Int) -> UInt8? {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else {
            return nil
        }
        return bytes[row * image.bytesPerRow]
    }
}
