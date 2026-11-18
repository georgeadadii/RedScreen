import Foundation

/// Opaque 8-bit RGB components encoded in the destination buffer's named colour space.
///
/// These are native-space byte values, not sRGB UI colours: no colour conversion is applied.
/// Callers choosing a colour in another space must convert it before constructing this value.
/// Alpha is deliberately not configurable. Black is exact in both sRGB and Display P3.
public struct RedactionFillColor: Equatable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let black = RedactionFillColor(red: 0, green: 0, blue: 0)
}

public enum RedactionRenderingError: Error, Equatable, Sendable {
    case missingPixelLayout
    case dimensionsMismatch
}

/// Destructively replaces pixels in a new, flattened raster without drawing or blending.
/// The source is immutable; the result retains only pixels and their non-sensitive layout.
public struct SolidFillRedactionRenderer: RedactionRenderer {
    public let fillColor: RedactionFillColor

    public init(fillColor: RedactionFillColor = .black) {
        self.fillColor = fillColor
    }

    public func render(
        document: RedactionDocument,
        sourceImage: DecodedPixels
    ) async throws -> DecodedPixels {
        try Task.checkCancellation()
        guard let layout = sourceImage.layout else {
            throw RedactionRenderingError.missingPixelLayout
        }
        guard layout.dimensions == document.pixelDimensions else {
            throw RedactionRenderingError.dimensionsMismatch
        }
        let plan = try RedactionRenderPlan(document: document)
        // Data's copy-on-write gives this mutation independent storage; never retain a second
        // pixel array or drawing surface. The working storage becomes the returned buffer.
        var bytes = sourceImage.bytes
        try bytes.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            for fill in plan.fills {
                for y in fill.y..<(fill.y + fill.height) {
                    try Task.checkCancellation()
                    let row = y * layout.bytesPerRow
                    for x in fill.x..<(fill.x + fill.width) {
                        let offset = row + x * layout.pixelFormat.bytesPerPixel
                        buffer[offset] = fillColor.red
                        buffer[offset + 1] = fillColor.green
                        buffer[offset + 2] = fillColor.blue
                        buffer[offset + 3] = 255
                    }
                }
            }
        }
        try Task.checkCancellation()
        return DecodedPixels(bytes: bytes, layout: layout)
    }
}
