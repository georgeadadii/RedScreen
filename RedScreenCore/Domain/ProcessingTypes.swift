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

/// Decoded image pixels retained only for the lifetime of an active session.
///
/// The bytes are intentionally represented without an AppKit dependency so a later image decoder
/// can choose its native pixel format while the lifecycle remains testable in RedScreenCore.
public final class DecodedPixels: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible {
    public let bytes: Data

    public init(bytes: Data) {
        self.bytes = bytes
    }

    public static func == (lhs: DecodedPixels, rhs: DecodedPixels) -> Bool {
        lhs.bytes == rhs.bytes
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
