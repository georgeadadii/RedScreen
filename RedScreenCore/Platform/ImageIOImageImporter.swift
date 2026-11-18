import CoreGraphics
import Foundation
import ImageIO

/// Grants and releases access to a user-selected file.
public protocol SecurityScopeProviding: Sendable {
    /// Returns true when access was started and must be balanced by `endAccess`.
    func beginAccess(to url: URL) -> Bool
    func endAccess(to url: URL)
}

/// Sandbox security-scoped access for Open panel and drag-and-drop URLs.
public struct URLSecurityScope: SecurityScopeProviding {
    public init() {}

    public func beginAccess(to url: URL) -> Bool {
        url.startAccessingSecurityScopedResource()
    }

    public func endAccess(to url: URL) {
        url.stopAccessingSecurityScopedResource()
    }
}

/// Imports PNG, JPEG, and HEIC screenshots with ImageIO, entirely in memory.
///
/// The pipeline is ordered so each check happens before the next allocation:
/// 1. Begin security-scoped access, check the file is a regular, non-empty file within the byte
///    limit, read at most `limit + 1` bytes, then close the file and release access.
/// 2. Identify the container from its contents; reject anything but PNG, JPEG, and HEIC/HEIF.
/// 3. Read pixel dimensions from the header and reject zero-sized or over-budget images, then
///    reject truncated or damaged containers (`ImageContainerValidator`), which ImageIO would
///    otherwise decode leniently with missing rows.
/// 4. Decode with the EXIF orientation applied, then draw into a canonical, tightly packed RGBA8
///    buffer in sRGB or Display P3. Only that buffer and its layout leave the importer.
///
/// No temporary files are written, nothing is cached by ImageIO, and nothing is logged.
public struct ImageIOImageImporter: ImageImporter {
    public let policy: ImageImportPolicy
    private let securityScope: any SecurityScopeProviding

    public init(
        policy: ImageImportPolicy = .standard,
        securityScope: any SecurityScopeProviding = URLSecurityScope()
    ) {
        self.policy = policy
        self.securityScope = securityScope
    }

    @concurrent
    public func importImage(from url: URL) async throws -> ImportedImage {
        guard url.isFileURL else { throw ImageImportError.notAFile }
        let data = try readContents(of: url)
        try Task.checkCancellation()
        let pixels = try decode(data)
        try Task.checkCancellation()
        guard let layout = pixels.layout else { throw ImageImportError.corruptImage }
        return ImportedImage(
            sourceIdentity: SourceImageIdentity(),
            pixelDimensions: layout.dimensions,
            pixels: pixels
        )
    }

    /// Decodes already-read bytes. Exposed for tests; production callers use `importImage`.
    func decode(_ data: Data) throws -> DecodedPixels {
        guard !data.isEmpty else { throw ImageImportError.emptyFile }

        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              let type = CGImageSourceGetType(source) as String? else {
            throw ImageImportError.unsupportedType
        }
        guard let format = SupportedImageFormat(rawValue: type) else {
            throw ImageImportError.unsupportedType
        }

        // Budgets first, from the raw header where the format allows, then full integrity.
        if let header = try ImageContainerValidator.headerDimensions(data, as: format) {
            try enforceBudget(width: header.width, height: header.height)
        }
        try ImageContainerValidator.validateStructure(data, as: format)
        guard CGImageSourceGetCount(source) > 0 else { throw ImageImportError.corruptImage }

        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
            as? [CFString: Any],
              let storedWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let storedHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        else {
            throw ImageImportError.corruptImage
        }
        guard storedWidth > 0, storedHeight > 0 else { throw ImageImportError.zeroSizedImage }
        try enforceBudget(width: storedWidth, height: storedHeight)

        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let swapsAxes = (5...8).contains(orientation)
        let width = swapsAxes ? storedHeight : storedWidth
        let height = swapsAxes ? storedWidth : storedHeight

        // The thumbnail API is ImageIO's supported way to apply EXIF orientation. Requesting the
        // full stored size makes it an upright, full-resolution decode rather than a downscale.
        let decodeOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(storedWidth, storedHeight),
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false,
        ] as CFDictionary
        guard CGImageSourceGetStatusAtIndex(source, index) == .statusComplete,
              let image = CGImageSourceCreateThumbnailAtIndex(source, index, decodeOptions),
              image.width == width, image.height == height else {
            throw ImageImportError.corruptImage
        }

        let colorSpace = Self.renderingColorSpace(for: image.colorSpace)
        let dimensions = try PixelDimensions(width: width, height: height)
        let layout = PixelBufferLayout(dimensions: dimensions, colorSpace: colorSpace)
        guard let cgColorSpace = CGColorSpace(name: colorSpace.cgName) else {
            throw ImageImportError.corruptImage
        }

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
        guard drawn else { throw ImageImportError.corruptImage }
        return DecodedPixels(bytes: bytes, layout: layout)
    }

    private func enforceBudget(width: Int, height: Int) throws {
        guard width <= policy.maximumDimension, height <= policy.maximumDimension else {
            throw ImageImportError.dimensionsTooLarge(limit: policy.maximumDimension)
        }
        let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixelCount <= policy.maximumPixelCount else {
            throw ImageImportError.pixelBudgetExceeded(limitPixels: policy.maximumPixelCount)
        }
    }

    // MARK: - File access

    private func readContents(of url: URL) throws -> Data {
        let didBeginAccess = securityScope.beginAccess(to: url)
        defer {
            if didBeginAccess { securityScope.endAccess(to: url) }
        }

        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        } catch {
            throw ImageImportError.unreadable
        }
        guard values.isRegularFile == true else { throw ImageImportError.notAFile }
        let size = values.fileSize ?? 0
        guard size > 0 else { throw ImageImportError.emptyFile }
        guard size <= policy.maximumFileBytes else {
            throw ImageImportError.fileTooLarge(limitBytes: policy.maximumFileBytes)
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw ImageImportError.unreadable
        }
        defer { try? handle.close() }

        // Re-check while reading: the file may have grown since its size was queried.
        let data: Data
        do {
            data = try handle.read(upToCount: policy.maximumFileBytes + 1) ?? Data()
        } catch {
            throw ImageImportError.unreadable
        }
        guard !data.isEmpty else { throw ImageImportError.emptyFile }
        guard data.count <= policy.maximumFileBytes else {
            throw ImageImportError.fileTooLarge(limitBytes: policy.maximumFileBytes)
        }
        return data
    }

    // MARK: - Colour

    /// Wide-gamut RGB sources keep their gamut in Display P3; everything else (sRGB, untagged,
    /// grayscale, indexed, CMYK) is converted to sRGB.
    static func renderingColorSpace(for colorSpace: CGColorSpace?) -> RenderingColorSpace {
        guard let colorSpace, colorSpace.model == .rgb, colorSpace.isWideGamutRGB else {
            return .sRGB
        }
        return .displayP3
    }
}

extension RenderingColorSpace {
    /// The Core Graphics colour space name backing this rendering space.
    public var cgName: CFString {
        switch self {
        case .sRGB: CGColorSpace.sRGB
        case .displayP3: CGColorSpace.displayP3
        }
    }
}
