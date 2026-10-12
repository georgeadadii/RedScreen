import Foundation

/// Loads image data chosen through an explicit user interaction.
public protocol ImageImporting: Sendable {
    func loadImage(from url: URL) async throws -> ScreenshotImage
}

/// Recognizes text locally from an in-memory screenshot.
public protocol TextRecognizing: Sendable {
    func recognizeText(in image: ScreenshotImage) async throws -> [RecognizedText]
}

/// Finds sensitive values in recognized text without external services.
public protocol SensitiveInformationDetecting: Sendable {
    func detectSensitiveInformation(in text: [RecognizedText]) async throws -> [SensitiveRegion]
}

/// Permanently applies redactions to an image in memory.
public protocol RedactionRendering: Sendable {
    func renderRedactions(
        on image: ScreenshotImage,
        regions: [SensitiveRegion]
    ) async throws -> ScreenshotImage
}

/// Writes an already-redacted image to a user-selected destination.
public protocol ImageExporting: Sendable {
    func export(_ image: ScreenshotImage, to destination: ExportDestination) async throws
}

/// Explicit dependency container for the future local processing pipeline.
public struct ProcessingDependencies: Sendable {
    public let imageImporter: any ImageImporting
    public let textRecognizer: any TextRecognizing
    public let detector: any SensitiveInformationDetecting
    public let renderer: any RedactionRendering
    public let exporter: any ImageExporting

    public init(
        imageImporter: any ImageImporting,
        textRecognizer: any TextRecognizing,
        detector: any SensitiveInformationDetecting,
        renderer: any RedactionRendering,
        exporter: any ImageExporting
    ) {
        self.imageImporter = imageImporter
        self.textRecognizer = textRecognizer
        self.detector = detector
        self.renderer = renderer
        self.exporter = exporter
    }
}
