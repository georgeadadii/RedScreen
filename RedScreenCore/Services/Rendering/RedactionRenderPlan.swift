import Foundation

/// The exact pixels a redaction renderer must overwrite for a document (issue #9, RED-5).
///
/// This is the first slice of the renderer: it decides **what** to paint, not how. Every region
/// of every `included` or `manual` candidate becomes an integer `PixelRect` using the document's
/// outward rounding (`ImageRect.enclosingPixelRect`: minimum edges floor, maximum edges ceil,
/// clamped to the image), so fractional and edge-touching rectangles can never leave a partially
/// covered source pixel. `pending` and `excluded` candidates contribute nothing. Fills are
/// de-duplicated and sorted top-to-bottom, then left-to-right, so rendering is deterministic.
///
/// The plan holds geometry only: no pixels, text, or candidate provenance.
public struct RedactionRenderPlan: Equatable, Sendable {
    public let dimensions: PixelDimensions
    public let fills: [PixelRect]

    public init(document: RedactionDocument) throws {
        let dimensions = document.pixelDimensions
        var fills: [PixelRect] = []
        for candidate in document.candidates where Self.isRendered(candidate.disposition) {
            for region in candidate.regions {
                let fill = try region.rect.enclosingPixelRect(in: dimensions)
                if !fills.contains(fill) { fills.append(fill) }
            }
        }
        self.dimensions = dimensions
        self.fills = fills.sorted {
            ($0.y, $0.x, $0.height, $0.width) < ($1.y, $1.x, $1.height, $1.width)
        }
    }

    /// Only candidates the user (or the safe default) chose to redact are painted.
    public static func isRendered(_ disposition: RedactionDisposition) -> Bool {
        switch disposition {
        case .included, .manual: true
        case .pending, .excluded: false
        }
    }

    /// True when the pixel at a top-left coordinate must be overwritten.
    public func covers(x: Int, y: Int) -> Bool {
        fills.contains { x >= $0.x && x < $0.x + $0.width && y >= $0.y && y < $0.y + $0.height }
    }
}
