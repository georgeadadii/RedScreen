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
/// - Fixed `en-US` language with automatic detection off, for deterministic results.
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
