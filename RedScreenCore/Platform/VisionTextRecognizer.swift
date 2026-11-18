import CoreGraphics
import Foundation
import Vision

/// On-device OCR with Apple Vision.
///
/// Settings (see docs/TEXT_RECOGNITION.md for rationale):
/// - `.accurate` recognition, the slower neural model that handles small monospace text best.
/// - Language correction **off**: correction could rewrite secret-like strings into dictionary
///   words, which would misplace or hide them from detection.
/// - No custom words: nothing derived from screenshots is handed to the recognizer, so there is
///   no vocabulary to persist.
/// - Fixed `en-US` language with automatic detection off, to avoid automatic model changes.
///
/// Vision runs locally; this type opens no network connection and writes nothing to disk. The
/// request is cancelled when the calling task is cancelled.
public struct VisionTextRecognizer: TextRecognizer {
    public struct Configuration: Equatable, Sendable {
        public let recognitionLanguages: [String]
        /// Minimum text height as a fraction of image height; 0 lets Vision decide.
        public let minimumTextHeight: Float

        public static let standard = Configuration(
            recognitionLanguages: ["en-US"],
            minimumTextHeight: 0
        )

        public init(recognitionLanguages: [String], minimumTextHeight: Float) {
            self.recognitionLanguages = recognitionLanguages
            self.minimumTextHeight = minimumTextHeight
        }
    }

    public let configuration: Configuration

    public init(configuration: Configuration = .standard) {
        self.configuration = configuration
    }

    @concurrent
    public func recognizeText(
        in pixels: DecodedPixels,
        dimensions: PixelDimensions
    ) async throws -> [OCRObservation] {
        guard let layout = pixels.layout, layout.dimensions == dimensions,
              let image = pixels.makeCGImage() else {
            throw TextRecognitionError.invalidImage
        }
        try Task.checkCancellation()

        let native = try await performRecognition(in: image)
        let heights = native.map { $0.boundingBox.height * Double(image.height) }.sorted()
        // Large glyphs can cause Vision to collapse punctuation (notably PEM dash runs).
        // Keep the native pass for small text and use a half-size pass only to refine matching
        // large-text lines. Normalized coordinates remain in the original image's unit grid.
        guard !heights.isEmpty, heights[heights.count / 2] >= 20,
              let smaller = Self.halfSizeImage(image) else { return native }
        try Task.checkCancellation()
        let secondary = try await performRecognition(in: smaller)
        let refined = Self.refining(native, with: secondary)
        try Task.checkCancellation()
        return refined
    }

    private func performRecognition(in image: CGImage) async throws -> [OCRObservation] {
        try Task.checkCancellation()
        let request = RequestBox(makeRequest())
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        try await withTaskCancellationHandler {
            do {
                try handler.perform([request.value])
            } catch {
                if Task.isCancelled { throw CancellationError() }
                throw TextRecognitionError.recognitionFailed
            }
        } onCancel: {
            request.value.cancel()
        }
        try Task.checkCancellation()

        return (request.value.results ?? []).compactMap(Self.observation(from:))
    }

    private static func halfSizeImage(_ image: CGImage) -> CGImage? {
        let width = max(1, image.width / 2)
        let height = max(1, image.height / 2)
        guard let space = image.colorSpace,
              let context = CGContext(data: nil, width: width, height: height,
                  bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// Match lines one-to-one so a secondary line cannot duplicate or reorder observations.
    /// Only expand collapsed dash runs when all other content agrees and confidence does not
    /// decrease. Never substitute different letters, digits, or syntax from the smaller pass.
    /// Native lines with no counterpart are retained, including small text in mixed-size images.
    static func refining(_ native: [OCRObservation], with secondary: [OCRObservation]) -> [OCRObservation] {
        var used: Set<UUID> = []
        return native.map { original in
            let box = original.boundingBox
            let matches = secondary.filter { other in
                guard !used.contains(other.id), other.boundingBoxOrigin == original.boundingBoxOrigin else { return false }
                let candidate = other.boundingBox
                let vertical = min(box.y + box.height, candidate.y + candidate.height) - max(box.y, candidate.y)
                let horizontal = min(box.x + box.width, candidate.x + candidate.width) - max(box.x, candidate.x)
                return vertical >= 0.5 * min(box.height, candidate.height)
                    && horizontal >= 0.7 * max(box.width, candidate.width)
            }
            matches.forEach { used.insert($0.id) }
            var best = original
            for candidate in matches {
                if candidate.confidence.value >= best.confidence.value,
                   Self.dashSkeleton(candidate.text) == Self.dashSkeleton(original.text),
                   candidate.text.filter({ !$0.isWhitespace }).count > best.text.filter({ !$0.isWhitespace }).count {
                    best = candidate
                }
            }
            return best
        }
    }

    private static func dashSkeleton(_ text: String) -> String {
        var result = ""
        var inDashRun = false
        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
            switch scalar.value {
            case 0x2D, 0x2010...0x2015, 0x2212, 0xFE58, 0xFE63, 0xFF0D:
                if !inDashRun { result.append("-") }
                inDashRun = true
            default:
                result.unicodeScalars.append(scalar)
                inDashRun = false
            }
        }
        return result
    }

    /// The configured Vision request. Internal so tests can verify its privacy settings.
    func makeRequest() -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.customWords = []
        request.recognitionLanguages = configuration.recognitionLanguages
        request.automaticallyDetectsLanguage = false
        request.minimumTextHeight = configuration.minimumTextHeight
        return request
    }

    // MARK: - Conversion

    /// Converts one Vision result. Vision boxes are normalized with a **bottom-left** origin and
    /// may extend fractionally past the image; they are clamped and the origin is recorded.
    static func observation(from result: VNRecognizedTextObservation) -> OCRObservation? {
        guard let candidate = result.topCandidates(1).first,
              !candidate.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let box = clampedRect(result.boundingBox) else {
            return nil
        }
        let text = candidate.string
        var segments: [OCRTextSegment] = []
        for range in wordRanges(in: text) {
            guard let wordBox = try? candidate.boundingBox(for: range),
                  let rect = clampedRect(wordBox.boundingBox) else {
                continue
            }
            let lower = range.lowerBound.utf16Offset(in: text)
            let upper = range.upperBound.utf16Offset(in: text)
            segments.append(OCRTextSegment(utf16Range: lower..<upper, boundingBox: rect))
        }
        guard let confidence = try? Confidence(min(1, max(0, Double(candidate.confidence)))) else {
            return nil
        }
        return OCRObservation(
            text: text,
            boundingBox: box,
            boundingBoxOrigin: .bottomLeft,
            confidence: confidence,
            segments: segments
        )
    }

    /// Ranges of maximal runs of non-whitespace characters.
    static func wordRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            if text[index].isWhitespace {
                if let wordStart = start { ranges.append(wordStart..<index) }
                start = nil
            } else if start == nil {
                start = index
            }
            index = text.index(after: index)
        }
        if let wordStart = start { ranges.append(wordStart..<text.endIndex) }
        return ranges
    }

    static func clampedRect(_ rect: CGRect) -> NormalizedRect? {
        guard rect.minX.isFinite, rect.minY.isFinite, rect.maxX.isFinite, rect.maxY.isFinite else {
            return nil
        }
        let minX = min(1, max(0, Double(rect.minX)))
        let minY = min(1, max(0, Double(rect.minY)))
        let maxX = min(1, max(0, Double(rect.maxX)))
        let maxY = min(1, max(0, Double(rect.maxY)))
        guard maxX > minX, maxY > minY, minX < 1, minY < 1 else { return nil }
        return try? NormalizedRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// Lets the non-Sendable Vision request be cancelled from the cancellation handler. Vision
/// documents `cancel()` as safe to call from another thread while `perform` is running.
private final class RequestBox: @unchecked Sendable {
    let value: VNRecognizeTextRequest

    init(_ value: VNRecognizeTextRequest) {
        self.value = value
    }
}

extension DecodedPixels {
    /// Wraps the buffer as a `CGImage` without copying it to disk. Returns nil for opaque test
    /// buffers that have no layout.
    public func makeCGImage() -> CGImage? {
        guard let layout,
              let colorSpace = CGColorSpace(name: layout.colorSpace.cgName),
              let provider = CGDataProvider(data: bytes as CFData) else {
            return nil
        }
        return CGImage(
            width: layout.dimensions.width,
            height: layout.dimensions.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: layout.bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}
