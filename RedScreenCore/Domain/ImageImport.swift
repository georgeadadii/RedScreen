import Foundation

/// Image container formats RedScreen accepts, identified from file contents rather than names.
public enum SupportedImageFormat: String, CaseIterable, Equatable, Sendable {
    case png = "public.png"
    case jpeg = "public.jpeg"
    case heic = "public.heic"
    case heif = "public.heif"

    public var typeIdentifier: String { rawValue }
}

/// Conservative limits applied before any pixel buffer is allocated.
///
/// Image decoders are an untrusted-input boundary. Every limit is checked from the file size and
/// container header first, so oversized or decompression-bomb inputs are rejected without being
/// decoded.
public struct ImageImportPolicy: Equatable, Sendable {
    /// Largest accepted encoded file. Real screenshots are far smaller.
    public let maximumFileBytes: Int
    /// Largest accepted width or height, in pixels.
    public let maximumDimension: Int
    /// Largest accepted pixel count; bounds the decoded buffer at `4 × maximumPixelCount` bytes.
    public let maximumPixelCount: Int

    public static let standard = ImageImportPolicy(
        maximumFileBytes: 64 * 1_024 * 1_024,
        maximumDimension: 16_384,
        maximumPixelCount: 64 * 1_024 * 1_024
    )

    public init(maximumFileBytes: Int, maximumDimension: Int, maximumPixelCount: Int) {
        precondition(maximumFileBytes > 0 && maximumDimension > 0 && maximumPixelCount > 0)
        self.maximumFileBytes = maximumFileBytes
        self.maximumDimension = maximumDimension
        self.maximumPixelCount = maximumPixelCount
    }

    public var maximumDecodedBytes: Int {
        maximumPixelCount * PixelFormat.rgba8PremultipliedLast.bytesPerPixel
    }
}

/// Why an import was rejected. Cases carry limits only, never paths, names, or metadata values.
public enum ImageImportError: Error, Equatable, Sendable, CustomStringConvertible {
    case notAFile
    case multipleItems
    case unreadable
    case emptyFile
    case fileTooLarge(limitBytes: Int)
    case unsupportedType
    case corruptImage
    case zeroSizedImage
    case dimensionsTooLarge(limit: Int)
    case pixelBudgetExceeded(limitPixels: Int)

    /// Actionable text for the UI. It never includes the file name or location.
    public var userMessage: String {
        switch self {
        case .notAFile:
            "Only image files can be imported. Choose a PNG, JPEG, or HEIC screenshot."
        case .multipleItems:
            "Import one screenshot at a time."
        case .unreadable:
            "The file couldn't be read. Check that it still exists and that you can open it."
        case .emptyFile:
            "The file is empty. Choose a screenshot that contains an image."
        case .fileTooLarge(let limit):
            "The file is larger than the \(Self.megabytes(limit)) import limit."
        case .unsupportedType:
            "RedScreen can import PNG, JPEG, and HEIC screenshots. Choose a file in one of those "
                + "formats."
        case .corruptImage:
            "The image is damaged or incomplete and couldn't be decoded."
        case .zeroSizedImage:
            "The image has no pixels. Choose a different screenshot."
        case .dimensionsTooLarge(let limit):
            "The image is too large to process safely. Each side must be at most \(limit) pixels."
        case .pixelBudgetExceeded(let limit):
            "The image is too large to process safely. The limit is "
                + "\(limit / 1_000_000) megapixels."
        }
    }

    public var description: String {
        switch self {
        case .notAFile: "notAFile"
        case .multipleItems: "multipleItems"
        case .unreadable: "unreadable"
        case .emptyFile: "emptyFile"
        case .fileTooLarge(let limit): "fileTooLarge(limitBytes: \(limit))"
        case .unsupportedType: "unsupportedType"
        case .corruptImage: "corruptImage"
        case .zeroSizedImage: "zeroSizedImage"
        case .dimensionsTooLarge(let limit): "dimensionsTooLarge(limit: \(limit))"
        case .pixelBudgetExceeded(let limit): "pixelBudgetExceeded(limitPixels: \(limit))"
        }
    }

    private static func megabytes(_ bytes: Int) -> String {
        "\(max(1, bytes / (1_024 * 1_024))) MB"
    }
}
