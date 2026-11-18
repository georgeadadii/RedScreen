import Foundation
import zlib

/// Structural integrity checks run before ImageIO sees the bytes.
///
/// ImageIO decodes truncated or damaged files leniently, filling missing rows with grey. A
/// redaction tool must not silently process a partial screenshot, so these checks reject
/// containers that are incomplete or fail their own checksums:
/// - PNG: signature, IHDR first, every chunk in bounds with a valid CRC-32, at least one IDAT,
///   and an IEND chunk. IHDR dimensions are read separately so budgets apply first.
/// - JPEG: SOI marker, and an EOI marker after the last start-of-scan.
/// - HEIC/HEIF: every top-level ISO BMFF box is in bounds and the boxes exactly span the file.
enum ImageContainerValidator {
    struct HeaderDimensions: Equatable {
        let width: Int
        let height: Int
    }

    /// Dimensions declared by the container header, read without decoding. Only PNG states them
    /// at a fixed position; other formats return nil and rely on ImageIO's header parse.
    static func headerDimensions(
        _ data: Data,
        as format: SupportedImageFormat
    ) throws -> HeaderDimensions? {
        guard format == .png else { return nil }
        let bytes = [UInt8](data.prefix(33))
        guard bytes.count == 33, Array(bytes[0..<8]) == pngSignature,
              readUInt32(bytes, at: 8) == 13,
              String(decoding: bytes[12..<16], as: UTF8.self) == "IHDR" else {
            throw ImageImportError.corruptImage
        }
        let width = Int(readUInt32(bytes, at: 16))
        let height = Int(readUInt32(bytes, at: 20))
        guard width > 0, height > 0 else { throw ImageImportError.zeroSizedImage }
        return HeaderDimensions(width: width, height: height)
    }

    /// Rejects truncated, damaged, or structurally incomplete containers.
    static func validateStructure(_ data: Data, as format: SupportedImageFormat) throws {
        let bytes = [UInt8](data)
        switch format {
        case .png: try validatePNG(bytes)
        case .jpeg: try validateJPEG(bytes)
        case .heic, .heif: try validateISOBMFF(bytes)
        }
    }

    // MARK: - PNG

    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    private static func validatePNG(_ bytes: [UInt8]) throws {
        guard bytes.count >= 8, Array(bytes[0..<8]) == pngSignature else {
            throw ImageImportError.corruptImage
        }
        var offset = 8
        var sawHeader = false
        var sawImageData = false

        while offset < bytes.count {
            guard offset + 12 <= bytes.count else { throw ImageImportError.corruptImage }
            let length = Int(readUInt32(bytes, at: offset))
            let typeStart = offset + 4
            let dataStart = offset + 8
            let (dataEnd, overflow) = dataStart.addingReportingOverflow(length)
            guard !overflow, length <= Int(Int32.max), dataEnd + 4 <= bytes.count else {
                throw ImageImportError.corruptImage
            }
            let type = String(decoding: bytes[typeStart..<dataStart], as: UTF8.self)
            let expectedCRC = readUInt32(bytes, at: dataEnd)
            let actualCRC = bytes.withUnsafeBufferPointer { buffer in
                UInt32(crc32(0, buffer.baseAddress! + typeStart, uInt(length + 4)))
            }
            guard expectedCRC == actualCRC else { throw ImageImportError.corruptImage }

            if !sawHeader {
                guard type == "IHDR", length == 13 else { throw ImageImportError.corruptImage }
                sawHeader = true
            }
            if type == "IDAT" { sawImageData = true }
            if type == "IEND" {
                guard sawImageData else { throw ImageImportError.corruptImage }
                return
            }
            offset = dataEnd + 4
        }
        // Ran out of bytes without IEND: truncated.
        throw ImageImportError.corruptImage
    }

    // MARK: - JPEG

    private static func validateJPEG(_ bytes: [UInt8]) throws {
        guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF else {
            throw ImageImportError.corruptImage
        }
        guard let lastScan = lastMarker(0xDA, in: bytes),
              let lastEnd = lastMarker(0xD9, in: bytes),
              lastEnd > lastScan else {
            throw ImageImportError.corruptImage
        }
    }

    private static func lastMarker(_ marker: UInt8, in bytes: [UInt8]) -> Int? {
        var index = bytes.count - 2
        while index >= 2 {
            if bytes[index] == 0xFF, bytes[index + 1] == marker { return index }
            index -= 1
        }
        return nil
    }

    // MARK: - HEIC / HEIF

    private static func validateISOBMFF(_ bytes: [UInt8]) throws {
        var offset = 0
        var sawFileType = false
        while offset < bytes.count {
            guard offset + 8 <= bytes.count else { throw ImageImportError.corruptImage }
            var size = Int(readUInt32(bytes, at: offset))
            let type = String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self)
            if offset == 0 {
                guard type == "ftyp" else { throw ImageImportError.corruptImage }
                sawFileType = true
            }
            switch size {
            case 0:
                size = bytes.count - offset
            case 1:
                guard offset + 16 <= bytes.count else { throw ImageImportError.corruptImage }
                let large = (UInt64(readUInt32(bytes, at: offset + 8)) << 32)
                    | UInt64(readUInt32(bytes, at: offset + 12))
                guard large >= 16, large <= UInt64(bytes.count - offset) else {
                    throw ImageImportError.corruptImage
                }
                size = Int(large)
            default:
                guard size >= 8 else { throw ImageImportError.corruptImage }
            }
            guard offset + size <= bytes.count else { throw ImageImportError.corruptImage }
            offset += size
        }
        guard sawFileType, offset == bytes.count else { throw ImageImportError.corruptImage }
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }
}
