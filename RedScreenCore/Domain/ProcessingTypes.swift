import Foundation

/// Opaque, immutable image data with explicit reference ownership.
///
/// `SecureImageSession` owns these buffers. The core module deliberately does not interpret,
/// serialize, or include their bytes in descriptions.
public final class ScreenshotImage: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible {
    public let data: Data

    public init(data: Data) {
        self.data = data
    }

    public static func == (lhs: ScreenshotImage, rhs: ScreenshotImage) -> Bool {
        lhs.data == rhs.data
    }

    public var description: String { "ScreenshotImage(<redacted>)" }
    public var debugDescription: String { description }
}

/// Memory layout of a pixel buffer.
public enum PixelFormat: Equatable, Sendable {
    /// Four 8-bit components per pixel in R, G, B, A order with premultiplied alpha.
    case rgba8PremultipliedLast

    public var bytesPerPixel: Int {
        switch self {
        case .rgba8PremultipliedLast: 4
        }
    }
}

/// The only colour metadata retained after import: the named RGB space the pixels are encoded in.
public enum RenderingColorSpace: Equatable, Sendable {
    case sRGB
    case displayP3
}

/// Describes how `DecodedPixels.bytes` map onto the canonical upright, top-left pixel grid.
///
/// Row 0 is the top of the upright image; rows are tightly packed.
public struct PixelBufferLayout: Equatable, Sendable {
    public let dimensions: PixelDimensions
    public let pixelFormat: PixelFormat
    public let colorSpace: RenderingColorSpace

    public init(
        dimensions: PixelDimensions,
        pixelFormat: PixelFormat = .rgba8PremultipliedLast,
        colorSpace: RenderingColorSpace
    ) {
        self.dimensions = dimensions
        self.pixelFormat = pixelFormat
        self.colorSpace = colorSpace
    }

    public var bytesPerRow: Int { dimensions.width * pixelFormat.bytesPerPixel }
    public var byteCount: Int { bytesPerRow * dimensions.height }
}

/// Decoded image pixels retained only for the lifetime of an active session.
///
/// The bytes are intentionally represented without an AppKit dependency so the lifecycle remains
/// testable in RedScreenCore. Pixels produced by an `ImageImporter` always carry a `layout`;
/// opaque test buffers may omit it.
public final class DecodedPixels: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible {
    public let bytes: Data
    public let layout: PixelBufferLayout?

    public init(bytes: Data, layout: PixelBufferLayout? = nil) {
        if let layout {
            precondition(bytes.count == layout.byteCount, "Pixel buffer does not match its layout")
        }
        self.bytes = bytes
        self.layout = layout
    }

    public static func == (lhs: DecodedPixels, rhs: DecodedPixels) -> Bool {
        lhs.layout == rhs.layout && lhs.bytes == rhs.bytes
    }

    public var description: String { "DecodedPixels(<redacted>)" }
    public var debugDescription: String { description }
}

public struct ExportDestination: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public var description: String { "ExportDestination(<redacted>)" }
    public var debugDescription: String { description }
}
