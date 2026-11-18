import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Encodes a flattened redacted image for saving or copying.
public protocol RedactedImageEncoding: Sendable {
    func encode(_ image: FlattenedRedactedImage) throws -> Data
}

/// Encodes PNG from the flattened raster alone, with a freshly built, minimal property set.
///
/// Nothing is copied from the imported file: import already discarded its container and
/// metadata. ImageIO's output is then filtered through a chunk allowlist, so the file holds
/// only image structure, pixel data, and the colour information needed to display it (the sRGB
/// or Display P3 profile, gamma, chromaticities, physical pixel size). Every other chunk is
/// dropped, including the `eXIf` chunk ImageIO adds by default, text chunks, timestamps, and
/// Apple's `iDOT` decoding hint, whose offsets would be invalid after filtering.
public struct ScrubbedPNGEncoder: RedactedImageEncoding {
    /// PNG chunk types allowed in the output.
    public static let allowedChunkTypes: Set<String> = [
        "IHDR", "PLTE", "IDAT", "IEND", "iCCP", "sRGB", "gAMA", "cHRM", "pHYs"
    ]

    public init() {}

    public func encode(_ image: FlattenedRedactedImage) throws -> Data {
        guard let cgImage = image.pixels.makeCGImage() else { throw ImageExportError.encodingFailed }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData, UTType.png.identifier as CFString, 1, nil
        ) else { throw ImageExportError.encodingFailed }
        // Allowlist: the properties dictionary is constructed here, never derived from a source.
        let properties: [CFString: Any] = [kCGImageDestinationEmbedThumbnail: false]
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImageExportError.encodingFailed }
        return try Self.keepingAllowedChunks(output as Data)
    }

    /// Rebuilds a PNG from its allowlisted chunks. Each chunk carries its own CRC, so copying
    /// chunks verbatim keeps them valid. Malformed input is rejected rather than passed through.
    static func keepingAllowedChunks(_ png: Data) throws -> Data {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let bytes = [UInt8](png)
        guard bytes.starts(with: signature) else { throw ImageExportError.encodingFailed }
        var result = Data(signature)
        var offset = signature.count
        var sawEnd = false
        while offset < bytes.count, !sawEnd {
            guard offset + 12 <= bytes.count else { throw ImageExportError.encodingFailed }
            let length = bytes[offset..<(offset + 4)].reduce(0) { $0 << 8 | Int($1) }
            let end = offset + 12 + length
            guard length <= Int(Int32.max), end <= bytes.count,
                  let type = String(bytes: bytes[(offset + 4)..<(offset + 8)], encoding: .ascii) else {
                throw ImageExportError.encodingFailed
            }
            if allowedChunkTypes.contains(type) {
                result.append(contentsOf: bytes[offset..<end])
            }
            sawEnd = type == "IEND"
            offset = end
        }
        guard sawEnd, offset == bytes.count else { throw ImageExportError.encodingFailed }
        return result
    }
}
