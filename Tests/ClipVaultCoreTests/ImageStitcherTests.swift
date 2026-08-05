import ClipVaultCore
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@Suite("Image stitcher")
struct ImageStitcherTests {
    @Test("Vertical stitch places frames by yOffset")
    func stitchPlacesFramesByOffset() throws {
        let top = try solidPNG(width: 4, height: 4, red: 1, green: 0, blue: 0)
        let bottom = try solidPNG(width: 4, height: 4, red: 0, green: 0, blue: 1)
        let stitched = try ImageStitcher.stitchVertically(
            frames: [
                .init(pngData: top, yOffset: 0),
                .init(pngData: bottom, yOffset: 4)
            ],
            canvasHeight: 8
        )

        let image = try #require(cgImage(from: stitched))
        #expect(image.width == 4)
        #expect(image.height == 8)
    }

    @Test("Scrolling stitch drops overlapping rows")
    func scrollingStitchDropsOverlap() throws {
        // Second frame reuses the last 4 logical rows of the first, then adds 4 new ones.
        let first = try stripedPNG(width: 8, height: 8, rowBase: 10)
        let second = try stripedPNG(width: 8, height: 8, rowBase: 14)
        let overlap = ImageStitcher.overlapRowCount(
            previous: try #require(cgImage(from: first)),
            next: try #require(cgImage(from: second))
        )
        #expect(overlap == 4)

        let stitched = try ImageStitcher.stitchScrollingCapture(pngFrames: [first, second])
        let image = try #require(cgImage(from: stitched))
        #expect(image.width == 8)
        #expect(image.height == 12)
    }

    @Test("Identical PNG samples compare equal")
    func identicalImagesMatch() throws {
        let a = try solidPNG(width: 8, height: 8, red: 0.2, green: 0.4, blue: 0.6)
        let b = try solidPNG(width: 8, height: 8, red: 0.2, green: 0.4, blue: 0.6)
        let c = try solidPNG(width: 8, height: 8, red: 0.9, green: 0.1, blue: 0.1)
        #expect(ImageStitcher.areVisuallyIdentical(a, b))
        #expect(!ImageStitcher.areVisuallyIdentical(a, c))
    }

    private func solidPNG(width: Int, height: Int, red: CGFloat, green: CGFloat, blue: CGFloat) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ImageStitcher.Error.contextFailed
        }
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            throw ImageStitcher.Error.contextFailed
        }
        return try encodePNG(image)
    }

    /// Each row has a distinct solid color derived from `rowBase + y` (top = rowBase).
    private func stripedPNG(width: Int, height: Int, rowBase: Int) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let value = UInt8((rowBase + y) % 200 + 20)
            // Bitmap buffer row 0 is bottom; write logical top (y=0) at the last row.
            let bufferY = height - 1 - y
            for x in 0..<width {
                let i = (bufferY * width + x) * 4
                pixels[i] = value
                pixels[i + 1] = 255 - value
                pixels[i + 2] = value / 2
                pixels[i + 3] = 255
            }
        }
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = context.makeImage() else {
            throw ImageStitcher.Error.contextFailed
        }
        return try encodePNG(image)
    }

    private func encodePNG(_ image: CGImage) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw ImageStitcher.Error.encodeFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageStitcher.Error.encodeFailed
        }
        return output as Data
    }

    private func cgImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
