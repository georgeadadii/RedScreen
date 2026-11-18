import CoreGraphics
import Foundation
import ImageIO
import XCTest

@testable import RedScreenCore

/// Builds small synthetic test images in memory and in a per-test temporary directory.
///
/// Everything here is synthetic: solid colour blocks with no text. Files live only in a unique
/// directory that the owning test removes.
struct TestImageFactory {
    struct RGBA: Equatable {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
        let alpha: UInt8

        static let red = RGBA(red: 255, green: 0, blue: 0, alpha: 255)
        static let green = RGBA(red: 0, green: 255, blue: 0, alpha: 255)
        static let blue = RGBA(red: 0, green: 0, blue: 255, alpha: 255)
        static let white = RGBA(red: 255, green: 255, blue: 255, alpha: 255)
        static let black = RGBA(red: 0, green: 0, blue: 0, alpha: 255)
        static let yellow = RGBA(red: 255, green: 255, blue: 0, alpha: 255)

        func isClose(to other: RGBA, tolerance: Int) -> Bool {
            abs(Int(red) - Int(other.red)) <= tolerance
                && abs(Int(green) - Int(other.green)) <= tolerance
                && abs(Int(blue) - Int(other.blue)) <= tolerance
                && abs(Int(alpha) - Int(other.alpha)) <= tolerance
        }
    }

    /// A stored grid of colour blocks, row 0 at the top.
    static func makeImage(
        blocks: [[RGBA]],
        blockSize: Int = 8,
        colorSpace: CFString = CGColorSpace.sRGB,
        alpha: Bool = false
    ) -> CGImage {
        let rows = blocks.count
        let columns = blocks[0].count
        let width = columns * blockSize
        let height = rows * blockSize
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let color = blocks[y / blockSize][x / blockSize]
                let offset = (y * width + x) * 4
                // Premultiplied storage.
                bytes[offset] = UInt8(Int(color.red) * Int(color.alpha) / 255)
                bytes[offset + 1] = UInt8(Int(color.green) * Int(color.alpha) / 255)
                bytes[offset + 2] = UInt8(Int(color.blue) * Int(color.alpha) / 255)
                bytes[offset + 3] = color.alpha
            }
        }
        let info: CGImageAlphaInfo = alpha ? .premultipliedLast : .noneSkipLast
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: colorSpace)!,
            bitmapInfo: CGBitmapInfo(rawValue: info.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }

    static func encode(
        _ image: CGImage,
        as type: String,
        orientation: Int? = nil,
        lossless: Bool = true
    ) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, type as CFString, 1, nil
        ) else {
            throw XCTSkip("ImageIO cannot encode \(type) on this machine")
        }
        var properties: [CFString: Any] = [:]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        if lossless { properties[kCGImageDestinationLossyCompressionQuality] = 1.0 }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw XCTSkip("ImageIO failed to encode \(type) on this machine")
        }
        return data as Data
    }
}

/// A unique, self-cleaning directory for files a test writes.
final class TemporaryTestDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RedScreenImportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    func write(_ data: Data, named name: String) throws -> URL {
        let fileURL = url.appendingPathComponent(name)
        try data.write(to: fileURL)
        return fileURL
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

extension DecodedPixels {
    /// Un-premultiplied pixel at an upright, top-left coordinate.
    func pixel(x: Int, y: Int) -> TestImageFactory.RGBA {
        let layout = self.layout!
        let offset = y * layout.bytesPerRow + x * 4
        let alpha = bytes[offset + 3]
        func unpremultiply(_ value: UInt8) -> UInt8 {
            alpha == 0 ? 0 : UInt8(min(255, (Int(value) * 255 + Int(alpha) / 2) / Int(alpha)))
        }
        return TestImageFactory.RGBA(
            red: unpremultiply(bytes[offset]),
            green: unpremultiply(bytes[offset + 1]),
            blue: unpremultiply(bytes[offset + 2]),
            alpha: alpha
        )
    }
}

/// Records security-scope calls so tests can prove access is always released.
final class SecurityScopeSpy: SecurityScopeProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var begins = 0
    private var ends = 0

    var beginCount: Int { lock.withLock { begins } }
    var endCount: Int { lock.withLock { ends } }

    func beginAccess(to url: URL) -> Bool {
        lock.withLock { begins += 1 }
        return true
    }

    func endAccess(to url: URL) {
        lock.withLock { ends += 1 }
    }
}
