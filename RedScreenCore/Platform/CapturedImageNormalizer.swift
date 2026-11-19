import CoreGraphics
import Foundation

/// Converts a freshly captured `CGImage` into the same canonical in-memory form as an import:
/// upright, tightly packed RGBA8 premultiplied-last pixels in sRGB or Display P3.
///
/// This is the capture side of the import normalization boundary. It enforces the import pixel
/// budget before allocating, keeps only pixels and their colour space, writes nothing, and treats
/// a fully transparent window capture as protected content.
public enum CapturedImageNormalizer {
    public static func normalize(
        _ image: CGImage,
        policy: ImageImportPolicy = .standard,
        treatsTransparentAsProtected: Bool
    ) throws -> ImportedImage {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { throw CaptureError.emptyRegion }
        let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        guard width <= policy.maximumDimension, height <= policy.maximumDimension,
              !overflow, pixelCount <= policy.maximumPixelCount else {
            throw CaptureError.tooLarge
        }
        let pixels: DecodedPixels
        do {
            pixels = try PixelNormalization.draw(image, width: width, height: height)
        } catch {
            throw CaptureError.failed
        }
        if treatsTransparentAsProtected, isFullyTransparent(pixels) {
            throw CaptureError.protectedContent
        }
        return ImportedImage(
            sourceIdentity: SourceImageIdentity(),
            pixelDimensions: try PixelDimensions(width: width, height: height),
            pixels: pixels
        )
    }

    static func isFullyTransparent(_ pixels: DecodedPixels) -> Bool {
        pixels.bytes.withUnsafeBytes { buffer in
            stride(from: 3, to: buffer.count, by: 4).allSatisfy { buffer[$0] == 0 }
        }
    }
}

/// Shared drawing step for imports and captures.
enum PixelNormalization {
    enum Failure: Error { case context }

    /// Draws `image` 1:1 (no interpolation, copy blend) into a new canonical buffer in the
    /// rendering colour space chosen for the image's own colour space.
    static func draw(_ image: CGImage, width: Int, height: Int) throws -> DecodedPixels {
        let colorSpace = ImageIOImageImporter.renderingColorSpace(for: image.colorSpace)
        let dimensions = try PixelDimensions(width: width, height: height)
        let layout = PixelBufferLayout(dimensions: dimensions, colorSpace: colorSpace)
        guard let cgColorSpace = CGColorSpace(name: colorSpace.cgName) else { throw Failure.context }
        var bytes = Data(count: layout.byteCount)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: layout.bytesPerRow,
                space: cgColorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            context.interpolationQuality = .none
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw Failure.context }
        return DecodedPixels(bytes: bytes, layout: layout)
    }
}
