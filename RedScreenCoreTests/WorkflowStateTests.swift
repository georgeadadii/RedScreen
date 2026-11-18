import Foundation
import XCTest

@testable import RedScreenCore

/// RED-8: the explicit import-to-export state machine, driven by controllable fakes so every
/// transition, cancellation, failure, and stale completion is deterministic.
@MainActor
final class WorkflowStateTests: XCTestCase {
    private var importer: ControlledImporter!
    private var recognizer: ControlledRecognizer!
    private var renderer: ControlledRenderer!
    private var exporter: ControlledExporter!
    private var lifecycle: SecureImageSessionLifecycle!
    private var controller: ScreenshotImportController!

    override func setUp() async throws {
        importer = ControlledImporter()
        recognizer = ControlledRecognizer()
        renderer = ControlledRenderer()
        exporter = ControlledExporter()
        lifecycle = SecureImageSessionLifecycle(logger: PrivacySafeLogger(sink: DiscardingSink()))
        controller = ScreenshotImportController(
            lifecycle: lifecycle,
            importer: importer,
            textRecognizer: recognizer,
            secretDetector: EmptyDetector(),
            candidateComposer: EmptyComposer(),
            renderer: renderer,
            imageExporter: exporter,
            logger: PrivacySafeLogger(sink: DiscardingSink())
        )
    }

    func testHappyPathVisitsEveryStateInOrder() async throws {
        XCTAssertEqual(controller.workflowState, .idle)
        let task = controller.importImage(from: url(10))
        XCTAssertEqual(controller.workflowState, .loading)
        XCTAssertTrue(controller.canCancelProcessing)
        await importer.gate.waitUntilRequested(10)
        await importer.gate.succeed(10)
        await task.value
        XCTAssertEqual(controller.workflowState, .recognizing)
        XCTAssertTrue(controller.canCancelProcessing)
        try await finishRecognition(10)
        XCTAssertEqual(controller.workflowState, .reviewing)
        XCTAssertFalse(controller.canCancelProcessing)

        let render = Task { try await controller.renderReviewedImage() }
        await renderer.gate.waitUntilRequested(0)
        XCTAssertEqual(controller.workflowState, .rendering)
        await renderer.gate.succeed(0)
        let image = try await render.value
        XCTAssertEqual(controller.workflowState, .reviewing)

        let export = Task {
            try await controller.exportReviewedImage(image, to: ExportDestination(url: URL(fileURLWithPath: "/synthetic/out.png")))
        }
        await exporter.gate.waitUntilRequested(0)
        XCTAssertEqual(controller.workflowState, .exporting)
        await exporter.gate.succeed(0)
        try await export.value
        XCTAssertEqual(controller.workflowState, .reviewing)

        controller.closeDocument()
        XCTAssertEqual(controller.workflowState, .idle)
        XCTAssertNil(lifecycle.activeSession)
    }

    func testCancelingImportWithoutDocumentDiscardsTheLateResult() async throws {
        let task = controller.importImage(from: url(10))
        await importer.gate.waitUntilRequested(10)
        controller.cancelProcessing()
        XCTAssertEqual(controller.workflowState, .canceled)
        await importer.gate.succeed(10)
        await task.value
        XCTAssertNil(controller.document)
        XCTAssertNil(lifecycle.activeSession)
        XCTAssertEqual(controller.workflowState, .canceled)

        // A new import leaves the canceled state.
        try await openDocument(11)
        XCTAssertEqual(controller.workflowState, .reviewing)
    }

    func testCancelingReplacementImportKeepsTheOpenDocument() async throws {
        try await openDocument(10)
        let open = try XCTUnwrap(controller.document)
        let task = controller.importImage(from: url(20))
        XCTAssertEqual(controller.workflowState, .loading)
        await importer.gate.waitUntilRequested(20)
        controller.cancelProcessing()
        await importer.gate.succeed(20)
        await task.value
        XCTAssertEqual(controller.document, open)
        XCTAssertEqual(controller.workflowState, .reviewing)
        XCTAssertNotNil(controller.activePixels)
    }

    func testCancelingRecognitionDiscardsItsResultUntilRetry() async throws {
        let task = controller.importImage(from: url(10))
        await importer.gate.waitUntilRequested(10)
        await importer.gate.succeed(10)
        await task.value
        await recognizer.gate.waitUntilRequested(10)
        controller.cancelProcessing()
        XCTAssertEqual(controller.workflowState, .canceled)
        XCTAssertFalse(controller.canCancelProcessing)
        await recognizer.gate.succeed(10)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(controller.workflowState, .canceled)
        XCTAssertEqual(controller.activeDocument?.observations, [])
        XCTAssertFalse(controller.canRenderReviewedImage, "A canceled document cannot be exported")

        controller.retryRecognition()
        XCTAssertEqual(controller.workflowState, .recognizing)
        try await finishRecognition(10)
        XCTAssertEqual(controller.workflowState, .reviewing)
    }

    func testRecognitionFailureIsExplicitAndRetryable() async throws {
        let task = controller.importImage(from: url(10))
        await importer.gate.waitUntilRequested(10)
        await importer.gate.succeed(10)
        await task.value
        await recognizer.gate.waitUntilRequested(10)
        await recognizer.gate.fail(10, TextRecognitionError.recognitionFailed)
        await controller.currentRecognition?.value
        XCTAssertEqual(controller.workflowState, .failed(.recognitionFailed(.recognitionFailed)))

        controller.retryRecognition()
        try await finishRecognition(10)
        XCTAssertEqual(controller.workflowState, .reviewing)
    }

    func testImportFailureIsAStateOnlyWithoutAnOpenDocument() async throws {
        let failing = controller.importImage(from: url(10))
        await importer.gate.waitUntilRequested(10)
        await importer.gate.fail(10, ImageImportError.corruptImage)
        await failing.value
        XCTAssertEqual(controller.workflowState, .failed(.importFailed(.corruptImage)))

        try await openDocument(11)
        let replacement = controller.importImage(from: url(12))
        await importer.gate.waitUntilRequested(12)
        await importer.gate.fail(12, ImageImportError.unsupportedType)
        await replacement.value
        XCTAssertEqual(controller.lastError, .unsupportedType)
        XCTAssertEqual(controller.workflowState, .reviewing, "The open document keeps its state")
        XCTAssertEqual(controller.document?.pixelDimensions.width, 11)
    }

    func testRapidReimportAppliesOnlyTheNewestImport() async throws {
        let tasks = [10, 11, 12].map { controller.importImage(from: url($0)) }
        for width in [10, 11, 12] { await importer.gate.waitUntilRequested(width) }
        await importer.gate.succeed(12)
        await importer.gate.succeed(10)
        await importer.gate.succeed(11)
        for task in tasks { await task.value }
        XCTAssertEqual(controller.document?.pixelDimensions.width, 12)
        try await finishRecognition(12)
        XCTAssertEqual(controller.workflowState, .reviewing)
        let requested = await recognizer.gate.requestedKeys
        XCTAssertEqual(requested, [12], "Superseded imports never start recognition")
    }

    func testReimportDuringRecognitionDiscardsTheStaleRecognition() async throws {
        let first = controller.importImage(from: url(10))
        await importer.gate.waitUntilRequested(10)
        await importer.gate.succeed(10)
        await first.value
        await recognizer.gate.waitUntilRequested(10)

        try await openDocument(11)
        let fresh = try XCTUnwrap(controller.activeDocument)
        await recognizer.gate.succeed(10)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(controller.activeDocument, fresh)
        XCTAssertEqual(controller.document?.pixelDimensions.width, 11)
    }

    func testClosingDuringEachProcessingStageReturnsToIdleAndDropsLateWork() async throws {
        // During import.
        let loading = controller.importImage(from: url(10))
        await importer.gate.waitUntilRequested(10)
        controller.closeDocument()
        XCTAssertEqual(controller.workflowState, .idle)
        await importer.gate.succeed(10)
        await loading.value
        XCTAssertNil(lifecycle.activeSession)

        // During recognition.
        let recognizing = controller.importImage(from: url(11))
        await importer.gate.waitUntilRequested(11)
        await importer.gate.succeed(11)
        await recognizing.value
        await recognizer.gate.waitUntilRequested(11)
        controller.closeDocument()
        await recognizer.gate.succeed(11)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(controller.workflowState, .idle)
        XCTAssertNil(lifecycle.activeSession)

        // During rendering: the result is refused.
        try await openDocument(12)
        let render = Task { try await controller.renderReviewedImage() }
        await renderer.gate.waitUntilRequested(0)
        controller.closeDocument()
        await renderer.gate.succeed(0)
        do {
            _ = try await render.value
            XCTFail("A render finishing after close must not be returned")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(controller.workflowState, .idle)
    }

    func testEditDuringRenderingInvalidatesTheResult() async throws {
        try await openDocument(10)
        let render = Task { try await controller.renderReviewedImage() }
        await renderer.gate.waitUntilRequested(0)
        XCTAssertNotNil(controller.addManualRedaction(try ImageRect(x: 0, y: 0, width: 2, height: 2)))
        await renderer.gate.succeed(0)
        do {
            _ = try await render.value
            XCTFail("A render of an older revision must not be returned")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(controller.workflowState, .reviewing)
    }

    func testFailedExportReturnsToReviewing() async throws {
        try await openDocument(10)
        let render = Task { try await controller.renderReviewedImage() }
        await renderer.gate.waitUntilRequested(0)
        await renderer.gate.succeed(0)
        let image = try await render.value
        let export = Task {
            try await controller.exportReviewedImage(image, to: ExportDestination(url: URL(fileURLWithPath: "/synthetic/out.png")))
        }
        await exporter.gate.waitUntilRequested(0)
        await exporter.gate.fail(0, ImageExportError.writeFailed)
        do {
            try await export.value
            XCTFail("Expected failure")
        } catch {
            XCTAssertEqual(error as? ImageExportError, .writeFailed)
        }
        XCTAssertEqual(controller.workflowState, .reviewing)
    }

    // MARK: - Helpers

    private func url(_ width: Int) -> URL { URL(fileURLWithPath: "/synthetic/\(width).png") }

    private func openDocument(_ width: Int) async throws {
        let task = controller.importImage(from: url(width))
        await importer.gate.waitUntilRequested(width)
        await importer.gate.succeed(width)
        await task.value
        try await finishRecognition(width)
    }

    private func finishRecognition(_ width: Int) async throws {
        await recognizer.gate.waitUntilRequested(width)
        await recognizer.gate.succeed(width)
        await controller.currentRecognition?.value
        await controller.currentDetection?.value
    }
}

// MARK: - Fakes

/// Parks each request (by integer key) until the test resolves it. Like slow platform work,
/// a parked request ignores cancellation and completes when resolved.
private actor Gate {
    private var parked: [Int: CheckedContinuation<(any Error)?, Never>] = [:]
    private var waiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var serial = 0
    private(set) var requestedKeys: [Int] = []

    func park(_ key: Int?) async throws {
        let key = key ?? nextSerial()
        requestedKeys.append(key)
        let error = await withCheckedContinuation { continuation in
            parked[key] = continuation
            waiters.removeValue(forKey: key)?.forEach { $0.resume() }
        }
        if let error { throw error }
    }

    func waitUntilRequested(_ key: Int) async {
        if parked[key] != nil { return }
        await withCheckedContinuation { waiters[key, default: []].append($0) }
    }

    func succeed(_ key: Int) { parked.removeValue(forKey: key)?.resume(returning: nil) }
    func fail(_ key: Int, _ error: any Error) { parked.removeValue(forKey: key)?.resume(returning: error) }

    private func nextSerial() -> Int {
        defer { serial += 1 }
        return serial
    }
}

private func syntheticPixels(width: Int) throws -> DecodedPixels {
    let layout = PixelBufferLayout(dimensions: try PixelDimensions(width: width, height: 4), colorSpace: .sRGB)
    return DecodedPixels(bytes: Data(repeating: 0x7F, count: layout.byteCount), layout: layout)
}

private final class ControlledImporter: ImageImporter {
    let gate = Gate()

    func importImage(from url: URL) async throws -> ImportedImage {
        let width = Int(url.deletingPathExtension().lastPathComponent) ?? 1
        try await gate.park(width)
        let pixels = try syntheticPixels(width: width)
        return ImportedImage(sourceIdentity: SourceImageIdentity(),
                             pixelDimensions: pixels.layout!.dimensions, pixels: pixels)
    }
}

/// Keyed by image width so each document's recognition is controlled separately.
private final class ControlledRecognizer: TextRecognizer {
    let gate = Gate()

    func recognizeText(in pixels: DecodedPixels, dimensions: PixelDimensions) async throws -> [OCRObservation] {
        try await gate.park(dimensions.width)
        return [OCRObservation(text: "synthetic", boundingBox: try NormalizedRect(x: 0, y: 0, width: 0.5, height: 0.5),
                               boundingBoxOrigin: .topLeft, confidence: try Confidence(0.9))]
    }
}

/// Requests are keyed 0, 1, 2… in call order.
private final class ControlledRenderer: RedactionRenderer {
    let gate = Gate()

    func render(document: RedactionDocument, sourceImage: DecodedPixels) async throws -> DecodedPixels {
        try await gate.park(nil)
        return try await SolidFillRedactionRenderer().render(document: document, sourceImage: sourceImage)
    }
}

private final class ControlledExporter: ImageExporter {
    let gate = Gate()

    func export(_ redactedImage: FlattenedRedactedImage, to destination: ExportDestination) async throws {
        try await gate.park(nil)
    }
}

private struct EmptyDetector: SecretDetector {
    func detectSecrets(in observations: [OCRObservation]) async throws -> [SecretDetection] { [] }
}

private struct EmptyComposer: CandidateComposer {
    func composeCandidates(from detections: [SecretDetection], observations: [OCRObservation],
                           pixels: DecodedPixels?, dimensions: PixelDimensions) throws -> [RedactionCandidate] { [] }
}

private struct DiscardingSink: PrivacyLogSink {
    func write(_ entry: PrivacyLogEntry) {}
}
