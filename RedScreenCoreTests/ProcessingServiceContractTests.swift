import Foundation
import XCTest

@testable import RedScreenCore

final class ProcessingServiceContractTests: XCTestCase {
    func testAllPhaseOneServicesComposeWithoutSwiftUI() throws {
        let dependencies = ProcessingDependencies(
            imageImporter: ImporterStub(),
            textRecognizer: RecognizerStub(),
            secretDetector: DetectorStub(),
            candidateComposer: ComposerStub(),
            redactionRenderer: RendererStub(),
            imageExporter: ExporterStub()
        )

        requireSendable(type(of: dependencies))
    }

    private func requireSendable<T: Sendable>(_: T.Type) {}
}

private struct ImporterStub: ImageImporter {
    func importImage(from url: URL) async throws -> ImportedImage {
        ImportedImage(
            sourceIdentity: SourceImageIdentity(),
            pixelDimensions: try PixelDimensions(width: 1, height: 1),
            pixels: DecodedPixels(bytes: Data())
        )
    }
}

private struct RecognizerStub: TextRecognizer {
    func recognizeText(
        in pixels: DecodedPixels,
        dimensions: PixelDimensions
    ) async throws -> [OCRObservation] {
        []
    }
}

private struct DetectorStub: SecretDetector {
    func detectSecrets(in observations: [OCRObservation]) async throws -> [SecretDetection] {
        []
    }
}

private struct ComposerStub: CandidateComposer {
    func composeCandidates(
        from detections: [SecretDetection],
        observations: [OCRObservation],
        pixels: DecodedPixels?,
        dimensions: PixelDimensions
    ) throws -> [RedactionCandidate] {
        []
    }
}

private struct RendererStub: RedactionRenderer {
    func render(document: RedactionDocument, sourceImage: DecodedPixels) async throws
        -> DecodedPixels {
        sourceImage
    }
}

private struct ExporterStub: ImageExporter {
    func export(_ redactedImage: ScreenshotImage, to destination: ExportDestination) async throws {}
}
