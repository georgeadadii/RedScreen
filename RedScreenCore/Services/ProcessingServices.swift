import Foundation

/// Result of an explicit user-selected import. It remains in memory and is not serializable.
///
/// The encoded source file is not retained: `pixels` holds only the orientation-normalized,
/// colour-normalized raster, so EXIF, GPS, maker notes, and other file metadata are discarded.
public struct ImportedImage: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let sourceIdentity: SourceImageIdentity
    public let pixelDimensions: PixelDimensions
    public let pixels: DecodedPixels

    public init(
        sourceIdentity: SourceImageIdentity,
        pixelDimensions: PixelDimensions,
        pixels: DecodedPixels
    ) {
        self.sourceIdentity = sourceIdentity
        self.pixelDimensions = pixelDimensions
        self.pixels = pixels
    }

    public var description: String {
        "ImportedImage(source: \(sourceIdentity.rawValue), image: <redacted>)"
    }
    public var debugDescription: String { description }
}

/// Reads an explicitly user-selected image and normalizes its orientation in memory.
public protocol ImageImporter: Sendable {
    func importImage(from url: URL) async throws -> ImportedImage
}

/// Produces sensitive OCR observations locally from the session's normalized pixels.
///
/// Implementations must run on device, honour task cancellation, write nothing to disk, and
/// return boxes in in-bounds normalized coordinates with their producer origin stated.
public protocol TextRecognizer: Sendable {
    func recognizeText(
        in pixels: DecodedPixels,
        dimensions: PixelDimensions
    ) async throws -> [OCRObservation]
}

/// Identifies rule evidence by OCR identity without copying matched secret strings.
public protocol SecretDetector: Sendable {
    func detectSecrets(in observations: [OCRObservation]) async throws -> [SecretDetection]
}

/// Converts detector evidence into the shared review/render candidate model.
///
/// `pixels` are the session's normalized pixels, used to measure character positions that OCR
/// does not report. Implementations must cover the whole value when they cannot measure.
public protocol CandidateComposer: Sendable {
    func composeCandidates(
        from detections: [SecretDetection],
        observations: [OCRObservation],
        pixels: DecodedPixels?,
        dimensions: PixelDimensions
    ) throws -> [RedactionCandidate]
}

/// Permanently applies included and manual regions to a new orientation-normalized raster.
/// The result contains only flattened pixels and layout metadata, with no source or annotations.
public protocol RedactionRenderer: Sendable {
    func render(document: RedactionDocument, sourceImage: DecodedPixels) async throws
        -> DecodedPixels
}

/// Writes only a flattened, reviewed render to an explicitly selected destination.
///
/// The parameter type cannot be built from source pixels outside RedScreenCore. Implementations
/// must not leave a partial destination, must not replace an existing file unless
/// `destination.replacesExistingItem`, must write no inherited metadata, and must not log or
/// retain the destination.
public protocol ImageExporter: Sendable {
    func export(_ redactedImage: FlattenedRedactedImage, to destination: ExportDestination) async throws
}

/// Explicit dependency container for the future local processing pipeline.
public struct ProcessingDependencies: Sendable {
    public let imageImporter: any ImageImporter
    public let textRecognizer: any TextRecognizer
    public let secretDetector: any SecretDetector
    public let candidateComposer: any CandidateComposer
    public let redactionRenderer: any RedactionRenderer
    public let imageExporter: any ImageExporter

    public init(
        imageImporter: any ImageImporter,
        textRecognizer: any TextRecognizer,
        secretDetector: any SecretDetector,
        candidateComposer: any CandidateComposer,
        redactionRenderer: any RedactionRenderer,
        imageExporter: any ImageExporter
    ) {
        self.imageImporter = imageImporter
        self.textRecognizer = textRecognizer
        self.secretDetector = secretDetector
        self.candidateComposer = candidateComposer
        self.redactionRenderer = redactionRenderer
        self.imageExporter = imageExporter
    }
}
