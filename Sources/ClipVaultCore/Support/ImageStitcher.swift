import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Vertical PNG stitcher for scrolling full-page capture.
public enum ImageStitcher {
    public struct Frame: Sendable, Equatable {
        public let pngData: Data
        /// Top edge of this frame on the final canvas, in pixels.
        public let yOffset: Int

        public init(pngData: Data, yOffset: Int) {
            self.pngData = pngData
            self.yOffset = yOffset
        }
    }

    public enum Error: Swift.Error, Equatable {
        case emptyFrames
        case invalidImage
        case contextFailed
        case encodeFailed
    }

    /// Composite frames onto a canvas of `canvasHeight`. Width comes from the first frame.
    public static func stitchVertically(frames: [Frame], canvasHeight: Int) throws -> Data {
        guard let first = frames.first else {
            throw Error.emptyFrames
        }
        guard canvasHeight > 0 else {
            throw Error.invalidImage
        }
        guard let firstImage = cgImage(from: first.pngData) else {
            throw Error.invalidImage
        }

        let width = firstImage.width
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: canvasHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw Error.contextFailed
        }

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: canvasHeight))

        for frame in frames {
            guard let image = cgImage(from: frame.pngData) else {
                throw Error.invalidImage
            }
            // CGContext origin is bottom-left; API offsets are top-down.
            let drawY = canvasHeight - frame.yOffset - image.height
            context.draw(
                image,
                in: CGRect(x: 0, y: drawY, width: image.width, height: image.height)
            )
        }

        guard let composed = context.makeImage() else {
            throw Error.contextFailed
        }
        return try pngData(from: composed)
    }

    /// Stitch successive scrolling viewport captures, dropping duplicated overlap rows.
    ///
    /// - ponytail: row-hash overlap only — sticky headers / lazy load can still ghost; feature-match if needed.
    public static func stitchScrollingCapture(pngFrames: [Data]) throws -> Data {
        guard let firstData = pngFrames.first else {
            throw Error.emptyFrames
        }
        guard let firstImage = cgImage(from: firstData) else {
            throw Error.invalidImage
        }

        var placed: [Frame] = [.init(pngData: firstData, yOffset: 0)]
        var canvasHeight = firstImage.height
        var previousData = firstData

        for nextData in pngFrames.dropFirst() {
            guard let previous = cgImage(from: previousData),
                  let next = cgImage(from: nextData) else {
                throw Error.invalidImage
            }
            guard previous.width == next.width else {
                throw Error.invalidImage
            }

            var overlap = overlapRowCount(previous: previous, next: next)
            if overlap == 0 {
                // ponytail: assumed stride when row-hash match fails (lazy-load / sticky UI).
                overlap = Int(Double(next.height) * 0.15)
            }
            let novelHeight = next.height - overlap
            guard novelHeight > 0 else {
                continue
            }
            guard let cropped = crop(next, top: overlap, height: novelHeight),
                  let croppedPNG = try? pngData(from: cropped) else {
                throw Error.encodeFailed
            }
            placed.append(.init(pngData: croppedPNG, yOffset: canvasHeight))
            canvasHeight += novelHeight
            previousData = nextData
        }

        return try stitchVertically(frames: placed, canvasHeight: canvasHeight)
    }

    /// True when two PNGs decode to the same size and sampled mid-row pixels match.
    public static func areVisuallyIdentical(_ lhs: Data, _ rhs: Data) -> Bool {
        guard let left = cgImage(from: lhs), let right = cgImage(from: rhs) else {
            return false
        }
        guard left.width == right.width, left.height == right.height else {
            return false
        }
        return sampleSignature(left) == sampleSignature(right)
    }

    /// Rows at the top of `next` that match the bottom of `previous`.
    public static func overlapRowCount(previous: CGImage, next: CGImage) -> Int {
        let height = min(previous.height, next.height)
        guard height > 0, previous.width == next.width else {
            return 0
        }
        let previousRows = rowHashes(previous)
        let nextRows = rowHashes(next)
        let maxOverlap = Int(Double(height) * 0.95)
        let probe = min(32, max(height / 5, 3))
        guard probe > 0, maxOverlap >= probe else {
            return 0
        }

        for candidate in stride(from: maxOverlap, through: probe, by: -1) {
            var matches = 0
            for i in 0..<probe {
                let previousIndex = previousRows.count - candidate + i
                if previousIndex >= 0,
                   previousIndex < previousRows.count,
                   nextRows[i] == previousRows[previousIndex] {
                    matches += 1
                }
            }
            if matches == probe {
                return candidate
            }
        }
        return 0
    }

    private static func crop(_ image: CGImage, top: Int, height: Int) -> CGImage? {
        let rect = CGRect(x: 0, y: top, width: image.width, height: height)
        return image.cropping(to: rect)
    }

    private static func rowHashes(_ image: CGImage) -> [UInt64] {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else {
            return []
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return []
        }
        // Bitmap contexts are bottom-left; flip so buffer row 0 matches image top.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var hashes = [UInt64](repeating: 0, count: height)
        for y in 0..<height {
            var hash: UInt64 = 2_166_136_261
            for x in stride(from: 0, to: width, by: max(width / 64, 1)) {
                let i = (y * width + x) * 4
                hash ^= UInt64(pixels[i])
                hash &*= 16_777_619
                hash ^= UInt64(pixels[i + 1])
                hash &*= 16_777_619
                hash ^= UInt64(pixels[i + 2])
                hash &*= 16_777_619
            }
            hashes[y] = hash
        }
        return hashes
    }

    private static func cgImage(from pngData: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(pngData as CFData, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func pngData(from image: CGImage) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw Error.encodeFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw Error.encodeFailed
        }
        return output as Data
    }

    private static func sampleSignature(_ image: CGImage) -> [UInt64] {
        let hashes = rowHashes(image)
        guard !hashes.isEmpty else {
            return []
        }
        let last = hashes.count - 1
        return [hashes[0], hashes[last / 2], hashes[last]]
    }
}
