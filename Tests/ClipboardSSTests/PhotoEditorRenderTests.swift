import AppKit
import CoreGraphics
import SwiftUI
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

    // MARK: - Output matches the preview

    @Test("flip then rotate is applied in the same order as the preview")
    func flipHorizontalThenRotate90MatchesPreviewOrder() throws {
        var state = PhotoEditorView.EditingState()
        state.isFlippedHorizontal = true
        state.rotation = .pi / 2

        let output = try Self.render(Self.quadrantImage(), state: state)

        // Source rows: [R R G G] / [B B Y Y]. Flip: [G G R R] / [Y Y B B].
        // Then a 90° clockwise turn: the left column, read bottom to top, becomes the top row.
        let expected: [[Pixel]] = [
            [.yellow, .green],
            [.yellow, .green],
            [.blue, .red],
            [.blue, .red],
        ]
        #expect(output.count == expected.count)
        #expect(output.first?.count == expected.first?.count)
        for (y, row) in expected.enumerated() {
            for (x, colour) in row.enumerated() {
                #expect(output[safe: y]?[safe: x]?.isClose(to: colour) == true, "pixel (\(x), \(y))")
            }
        }
    }

    @Test("a Retina image saves at its pixel size, not its point size")
    func retinaImageRendersAtPixelSize() throws {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 100,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        rep.size = CGSize(width: 100, height: 50)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)

        let rendered = try #require(PhotoEditorView.renderedImage(from: image, state: .init()))
        let saved = try #require(rendered.pngData().flatMap(NSBitmapImageRep.init(data:)))

        #expect(saved.pixelsWide == 200)
        #expect(saved.pixelsHigh == 100)
    }

    @Test("the 1:1 preset gives a square crop in pixels on a 16:9 image")
    func squarePresetOn16by9ImageYieldsSquarePixels() {
        let pixelSize = CGSize(width: 1600, height: 900)
        let crop = PhotoEditorView.aspectCrop(ratio: 1, state: .init(), imagePixelSize: pixelSize)

        let width = crop.width * pixelSize.width
        let height = crop.height * pixelSize.height
        #expect(abs(width - height) < 0.5, "crop is \(width) x \(height) pixels")
        #expect(abs(crop.midX - 0.5) < 0.001)
        #expect(abs(crop.midY - 0.5) < 0.001)
    }

    @Test("a stroke drawn over a pixel after a crop lands on that pixel in the saved image")
    func annotationAfterCropLandsOnSameImagePoint() throws {
        let pixelSize = CGSize(width: 4, height: 2)
        let viewSize = CGSize(width: 400, height: 300)
        var state = PhotoEditorView.EditingState()
        state.cropRectNormalized = CGRect(x: 0.5, y: 0, width: 0.5, height: 1) // keeps [G G] / [Y Y]

        // The preview draws the image through displayTransform, and the drag gesture maps back
        // through its inverse. Centre of source pixel (3, 1), yellow, as shown on screen:
        let display = PhotoEditorView.displayTransform(state: state, imagePixelSize: pixelSize, viewSize: viewSize)
        let onScreen = CGPoint(x: 3.5, y: 1.5).applying(display)
        let stored = onScreen.applying(display.inverted())
        state.paths = [DrawingPath(
            points: [stored, CGPoint(x: stored.x + 0.01, y: stored.y)],
            color: Color(.sRGB, red: 1, green: 0, blue: 1, opacity: 1),
            lineWidth: 1.2,
            opacity: 1,
            isEraser: false
        )]

        let output = try Self.render(Self.quadrantImage(), state: state)

        #expect(output.count == 2)
        #expect(output.first?.count == 2)
        #expect(output[safe: 1]?[safe: 1]?.isClose(to: .magenta) == true, "stroke missed the yellow pixel")
        #expect(output[safe: 0]?[safe: 0]?.isClose(to: .green) == true)
    }

    // MARK: - Helpers

    struct Pixel: Equatable {
        var r: Int, g: Int, b: Int, a: Int
        static let red = Pixel(r: 255, g: 0, b: 0, a: 255)
        static let green = Pixel(r: 0, g: 255, b: 0, a: 255)
        static let blue = Pixel(r: 0, g: 0, b: 255, a: 255)
        static let yellow = Pixel(r: 255, g: 255, b: 0, a: 255)
        static let magenta = Pixel(r: 255, g: 0, b: 255, a: 255)

        func isClose(to other: Pixel) -> Bool {
            abs(r - other.r) < 40 && abs(g - other.g) < 40 && abs(b - other.b) < 40 && abs(a - other.a) < 40
        }
    }

    /// 4x2 pixels: top row red, red, green, green; bottom row blue, blue, yellow, yellow.
    private static func quadrantImage() throws -> CGImage {
        let rows: [[Pixel]] = [
            [.red, .red, .green, .green],
            [.blue, .blue, .yellow, .yellow],
        ]
        let bytes = rows.flatMap { $0 }.flatMap { [UInt8($0.r), UInt8($0.g), UInt8($0.b), UInt8($0.a)] }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        return try #require(CGImage(
            width: 4, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 16,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
    }

    /// Renders through the editor's save path and returns the output pixels, row 0 at the top.
    private static func render(_ source: CGImage, state: PhotoEditorView.EditingState) throws -> [[Pixel]] {
        let input = NSImage(cgImage: source, size: CGSize(width: source.width, height: source.height))
        let rendered = try #require(PhotoEditorView.renderedImage(from: input, state: state))
        let output = try #require(rendered.cgImage(forProposedRect: nil, context: nil, hints: nil))
        return try pixels(of: output)
    }

    private static func pixels(of image: CGImage) throws -> [[Pixel]] {
        let width = image.width, height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        try buffer.withUnsafeMutableBytes { raw in
            let context = try #require(CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return (0..<height).map { y in
            (0..<width).map { x in
                let i = (y * width + x) * 4
                return Pixel(r: Int(buffer[i]), g: Int(buffer[i + 1]), b: Int(buffer[i + 2]), a: Int(buffer[i + 3]))
            }
        }
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

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
