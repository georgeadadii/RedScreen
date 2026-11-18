import Foundation

/// Result of an explicit user-selected import. It remains in memory and is not serializable.
public struct ImportedImage: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let sourceIdentity: SourceImageIdentity
    public let pixelDimensions: PixelDimensions
    public let image: ScreenshotImage

    public init(
        sourceIdentity: SourceImageIdentity,
        pixelDimensions: PixelDimensions,
        image: ScreenshotImage
    ) {
        self.sourceIdentity = sourceIdentity
        self.pixelDimensions = pixelDimensions
        self.image = image
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

/// Produces sensitive OCR observations locally from an in-memory image.
public protocol TextRecognizer: Sendable {
    func recognizeText(
        in image: ScreenshotImage,
        dimensions: PixelDimensions
    ) async throws -> [OCRObservation]
}

/// Identifies rule evidence by OCR identity without copying matched secret strings.
public protocol SecretDetector: Sendable {
    func detectSecrets(in observations: [OCRObservation]) async throws -> [SecretDetection]
}

/// Converts detector evidence into the shared review/render candidate model.
public protocol CandidateComposer: Sendable {
    func composeCandidates(
        from detections: [SecretDetection],
        observations: [OCRObservation],
        dimensions: PixelDimensions
    ) throws -> [RedactionCandidate]
}

/// Permanently applies included and manual regions to a new in-memory image.
public protocol RedactionRenderer: Sendable {
    func render(document: RedactionDocument, sourceImage: ScreenshotImage) async throws
        -> ScreenshotImage
}

/// Writes only an already-rendered image to an explicitly selected destination.
public protocol ImageExporter: Sendable {
    func export(_ redactedImage: ScreenshotImage, to destination: ExportDestination) async throws
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
