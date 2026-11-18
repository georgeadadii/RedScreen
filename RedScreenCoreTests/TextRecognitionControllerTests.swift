import Foundation
import XCTest

@testable import RedScreenCore

/// Protocol-level OCR orchestration tests with fake recognizers (issue #6).
@MainActor
final class TextRecognitionControllerTests: XCTestCase {
    func testImportRunsRecognitionAndStoresObservationsInTheSessionDocument() async throws {
        let sink = EventSink()
        let lifecycle = SecureImageSessionLifecycle(logger: PrivacySafeLogger(sink: EventSink()))
        let controller = ScreenshotImportController(
            lifecycle: lifecycle,
            importer: SizedImporter(),
            textRecognizer: FixedRecognizer(count: 3),
            logger: PrivacySafeLogger(sink: sink)
        )

        await controller.importImage(from: url(width: 4)).value
        await controller.currentRecognition?.value

        XCTAssertEqual(controller.recognitionStatus, .recognized(observationCount: 3))
        let document = try XCTUnwrap(controller.activeDocument)
        XCTAssertEqual(document.observations.count, 3)
        XCTAssertEqual(document.processingState, .textRecognized)
        XCTAssertTrue(lifecycle.activeSession?.redactionDocument == document)
        XCTAssertEqual(Set(document.observations.map(\.id)).count, 3, "IDs must be unique")
        XCTAssertEqual(sink.events.filter { $0 != .textRecognitionDuration }, [
            .imageImported, .textRecognized,
        ])
        XCTAssertEqual(sink.entries.first { $0.event == .textRecognized }?.count, 3)
        XCTAssertTrue(sink.events.contains(.textRecognitionDuration))
    }

    func testRecognitionFailureIsRecoverableAndRetryable() async throws {
        let recognizer = FlakyRecognizer()
        let controller = ScreenshotImportController(
            lifecycle: SecureImageSessionLifecycle(logger: PrivacySafeLogger(sink: EventSink())),
            importer: SizedImporter(),
            textRecognizer: recognizer
        )

        await controller.importImage(from: url(width: 4)).value
        await controller.currentRecognition?.value

        XCTAssertEqual(controller.recognitionStatus, .failed(.recognitionFailed))
        XCTAssertNotNil(controller.document, "The image stays open after an OCR failure")
        XCTAssertEqual(controller.activeDocument?.processingState, .failed(.recognitionFailed))
        XCTAssertTrue(controller.activeDocument?.observations.isEmpty ?? false)

        await controller.retryRecognition()?.value
        XCTAssertEqual(controller.recognitionStatus, .recognized(observationCount: 1))
        XCTAssertEqual(controller.activeDocument?.processingState, .textRecognized)
    }

    func testNewDocumentCancelsAndDiscardsThePreviousRecognition() async throws {
        let recognizer = GatedRecognizer()
        let lifecycle = SecureImageSessionLifecycle(logger: PrivacySafeLogger(sink: EventSink()))
        let controller = ScreenshotImportController(
            lifecycle: lifecycle, importer: SizedImporter(), textRecognizer: recognizer
        )

        await controller.importImage(from: url(width: 3)).value
        let staleRecognition = try XCTUnwrap(controller.currentRecognition)
        await recognizer.waitUntilRequested(width: 3)
        let firstSession = try XCTUnwrap(lifecycle.activeSession)

        await controller.importImage(from: url(width: 7)).value
        await recognizer.waitUntilRequested(width: 7)
        let oldCancelled = await recognizer.wasCancelled(width: 3)
        XCTAssertTrue(oldCancelled, "Old OCR must be cancelled")

        // The old recognizer ignores cancellation and still returns: the result is discarded.
        await recognizer.release(width: 3, count: 9)
        await staleRecognition.value
        XCTAssertNil(firstSession.redactionDocument)
        XCTAssertEqual(controller.recognitionStatus, .recognizing)
        XCTAssertTrue(controller.activeDocument?.observations.isEmpty ?? false)

        await recognizer.release(width: 7, count: 2)
        await controller.currentRecognition?.value
        XCTAssertEqual(controller.recognitionStatus, .recognized(observationCount: 2))
        XCTAssertEqual(controller.activeDocument?.pixelDimensions.width, 7)
    }

    func testFailedImportDoesNotInterruptTheOpenDocumentsRecognition() async throws {
        let recognizer = GatedRecognizer()
        let controller = ScreenshotImportController(
            lifecycle: SecureImageSessionLifecycle(logger: PrivacySafeLogger(sink: EventSink())),
            importer: SizedImporter(),
            textRecognizer: recognizer
        )

        await controller.importImage(from: url(width: 5)).value
        let recognition = try XCTUnwrap(controller.currentRecognition)
        await recognizer.waitUntilRequested(width: 5)

        await controller.importImage(from: URL(fileURLWithPath: "/synthetic/corrupt.png")).value
        XCTAssertEqual(controller.lastError, .corruptImage)
        let interrupted = await recognizer.wasCancelled(width: 5)
        XCTAssertFalse(interrupted)

        await recognizer.release(width: 5, count: 4)
        await recognition.value
        XCTAssertEqual(controller.recognitionStatus, .recognized(observationCount: 4))
    }

    func testClosingTheDocumentCancelsRecognitionAndIgnoresItsResult() async throws {
        let recognizer = GatedRecognizer()
        let lifecycle = SecureImageSessionLifecycle(logger: PrivacySafeLogger(sink: EventSink()))
        let controller = ScreenshotImportController(
            lifecycle: lifecycle, importer: SizedImporter(), textRecognizer: recognizer
        )

        await controller.importImage(from: url(width: 6)).value
        let recognition = try XCTUnwrap(controller.currentRecognition)
        await recognizer.waitUntilRequested(width: 6)

        controller.closeDocument()
        let cancelled = await recognizer.wasCancelled(width: 6)
        XCTAssertTrue(cancelled)
        await recognizer.release(width: 6, count: 3)
        await recognition.value

        XCTAssertEqual(controller.recognitionStatus, .idle)
        XCTAssertNil(controller.activeDocument)
        XCTAssertNil(lifecycle.activeSession)
    }

    func testRecognitionLogsCountsAndTimingButNeverText() async throws {
        let sink = EventSink()
        let controller = ScreenshotImportController(
            lifecycle: SecureImageSessionLifecycle(logger: PrivacySafeLogger(sink: sink)),
            importer: SizedImporter(),
            textRecognizer: FixedRecognizer(count: 2, text: "password=RSFAKE-log-canary"),
            logger: PrivacySafeLogger(sink: sink)
        )

        await controller.importImage(from: url(width: 4)).value
        await controller.currentRecognition?.value

        let serialized = sink.entries.map { "\($0.event.rawValue)=\($0.count)" }
            .joined(separator: " ")
        XCTAssertFalse(serialized.contains("RSFAKE"))
        XCTAssertFalse(serialized.contains("password"))
        XCTAssertTrue(serialized.contains("text_recognized=2"))
    }

    func testSecretDetectionRunsAfterRecognitionAndStoresFindings() async throws {
        let sink = EventSink()
        let controller = ScreenshotImportController(
            lifecycle: SecureImageSessionLifecycle(logger: PrivacySafeLogger(sink: EventSink())),
            importer: SizedImporter(),
            textRecognizer: FixedRecognizer(count: 2, text: "DATABASE_PASSWORD=RSFAKE-pg-7d1c9a42"),
            secretDetector: ContextualSecretDetector(),
            logger: PrivacySafeLogger(sink: sink)
        )

        await controller.importImage(from: url(width: 4)).value
        await controller.currentRecognition?.value
        await controller.currentDetection?.value

        XCTAssertEqual(controller.detectionStatus, .detected(likely: 2, needsReview: 0))
        let document = try XCTUnwrap(controller.activeDocument)
        XCTAssertEqual(document.processingState, .secretsDetected)
        XCTAssertEqual(document.detections.count, 2)
        XCTAssertTrue(document.detections.allSatisfy { $0.family == .envAssignment })
        let serialized = sink.entries.map { "\($0.event.rawValue)=\($0.count)" }.joined(separator: " ")
        XCTAssertTrue(serialized.contains("sensitive_information_detected=2"))
        XCTAssertTrue(serialized.contains("detections_needing_review=0"))
        XCTAssertFalse(serialized.contains("RSFAKE"))
    }

    func testComposedCandidatesAreStoredReadyForReview() async throws {
        let sink = EventSink()
        let controller = ScreenshotImportController(
            lifecycle: SecureImageSessionLifecycle(logger: PrivacySafeLogger(sink: EventSink())),
            importer: SizedImporter(),
            textRecognizer: FixedRecognizer(count: 2, text: "DATABASE_PASSWORD=RSFAKE-pg-7d1c9a42"),
            secretDetector: ContextualSecretDetector(),
            candidateComposer: GeometricCandidateComposer(),
            logger: PrivacySafeLogger(sink: sink)
        )

        await controller.importImage(from: url(width: 400)).value
        await controller.currentRecognition?.value
        await controller.currentDetection?.value

        let document = try XCTUnwrap(controller.activeDocument)
        XCTAssertEqual(document.processingState, .readyForReview)
        // The fake image is only 2 px tall, so both padded lines overlap and merge into one
        // candidate carrying both findings.
        XCTAssertFalse(document.candidates.isEmpty)
        XCTAssertTrue(document.candidates.allSatisfy { $0.disposition == .included })
        XCTAssertEqual(Set(document.candidates.flatMap(\.detectionIDs)), Set(document.detections.map(\.id)))
        XCTAssertTrue(sink.events.contains(.candidatesComposed))
    }

    func testReplacingDocumentDiscardsPendingDetection() async throws {
        let controller = ScreenshotImportController(
            lifecycle: SecureImageSessionLifecycle(logger: PrivacySafeLogger(sink: EventSink())),
            importer: SizedImporter(),
            textRecognizer: FixedRecognizer(count: 1, text: "API_KEY=RSFAKE-key-6b2d91"),
            secretDetector: SlowDetector()
        )
        await controller.importImage(from: url(width: 4)).value
        await controller.currentRecognition?.value
        let staleDetection = try XCTUnwrap(controller.currentDetection)

        await controller.importImage(from: url(width: 9)).value
        await staleDetection.value
        XCTAssertNotEqual(controller.detectionStatus, .detected(likely: 1, needsReview: 0))
        XCTAssertEqual(controller.activeDocument?.pixelDimensions.width, 9)
        XCTAssertTrue(controller.activeDocument?.detections.isEmpty ?? false)
    }

    func testReviewEditsUndoRedoAndRenderOnlyResolvedCandidates() async throws {
        let controller = ScreenshotImportController(
            lifecycle: SecureImageSessionLifecycle(),
            importer: SizedImporter(),
            textRecognizer: FixedRecognizer(count: 1),
            secretDetector: SlowDetector(),
            candidateComposer: PendingReviewComposer()
        )
        await controller.importImage(from: url(width: 12)).value
        await controller.currentRecognition?.value
        await controller.currentDetection?.value
        let original = try XCTUnwrap(controller.activeDocument)
        let pending = try XCTUnwrap(original.candidates.first)
        XCTAssertTrue(controller.canReview)
        XCTAssertEqual(controller.pendingReviewCount, 1)
        XCTAssertFalse(controller.canRenderReviewedImage)
        do {
            _ = try await controller.renderReviewedImage()
            XCTFail("Pending candidates must block output")
        } catch let error as ReviewRenderError {
            XCTAssertEqual(error, .reviewRequired)
        }

        XCTAssertFalse(controller.deleteManualRedaction(pending.id))
        XCTAssertTrue(controller.setReviewDisposition(.excluded, for: pending.id))
        XCTAssertFalse(controller.setReviewDisposition(.excluded, for: pending.id))
        XCTAssertTrue(controller.canRenderReviewedImage)
        controller.undoReview()
        XCTAssertFalse(controller.canRenderReviewedImage)
        XCTAssertEqual(controller.activeDocument, original)
        controller.redoReview()
        XCTAssertTrue(controller.canRenderReviewedImage)

        let added = try ImageRect(x: 3, y: 0, width: 2, height: 1)
        let edited = try ImageRect(x: 5, y: 0, width: 3, height: 2)
        let id = try XCTUnwrap(controller.addManualRedaction(added))
        XCTAssertTrue(controller.updateManualRedaction(id, rect: edited))
        XCTAssertFalse(controller.updateManualRedaction(id, rect: try ImageRect(x: 11, y: 0, width: 2, height: 1)))
        controller.undoReview()
        XCTAssertEqual(controller.activeDocument?.candidates.last?.regions.first?.rect, added)
        controller.redoReview()
        XCTAssertEqual(controller.activeDocument?.candidates.last?.regions.first?.rect, edited)
        XCTAssertTrue(controller.deleteManualRedaction(id))
        XCTAssertEqual(controller.activeDocument?.candidates.count, 1)
        controller.undoReview()
        XCTAssertEqual(controller.activeDocument?.candidates.last?.id, id)

        let output = try await controller.renderReviewedImage()
        let alpha = stride(from: 3, to: output.bytes.count, by: 4).map { output.bytes[$0] }
        for i in alpha.indices {
            XCTAssertEqual(alpha[i], (5..<8).contains(i % 12) ? 255 : 0)
        }
        XCTAssertTrue(controller.deleteManualRedaction(id))
        XCTAssertFalse(controller.canRedoReview)

        await controller.importImage(from: url(width: 16)).value
        await controller.currentRecognition?.value
        await controller.currentDetection?.value
        XCTAssertFalse(controller.canUndoReview)
        XCTAssertFalse(controller.canRedoReview)
        XCTAssertEqual(controller.pendingReviewCount, 1)
        XCTAssertFalse(controller.updateManualRedaction(id, rect: edited))
        controller.closeDocument()
        XCTAssertFalse(controller.canReview)
        XCTAssertFalse(controller.canRenderReviewedImage)
    }

    // MARK: - Helpers

    private func url(width: Int) -> URL {
        URL(fileURLWithPath: "/synthetic/\(width).png")
    }
}

// MARK: - Fakes

private func pixels(width: Int) throws -> ImportedImage {
    let dimensions = try PixelDimensions(width: width, height: 2)
    let layout = PixelBufferLayout(dimensions: dimensions, colorSpace: .sRGB)
    return ImportedImage(
        sourceIdentity: SourceImageIdentity(),
        pixelDimensions: dimensions,
        pixels: DecodedPixels(bytes: Data(count: layout.byteCount), layout: layout)
    )
}

/// Imports `/synthetic/<width>.png` as a width × 2 image; anything else is corrupt.
private struct SizedImporter: ImageImporter {
    func importImage(from url: URL) async throws -> ImportedImage {
        guard let width = Int(url.deletingPathExtension().lastPathComponent) else {
            throw ImageImportError.corruptImage
        }
        return try pixels(width: width)
    }
}

private func observations(count: Int, text: String = "synthetic text") throws -> [OCRObservation] {
    try (0..<count).map { index in
        OCRObservation(
            text: text,
            boundingBox: try NormalizedRect(
                x: 0.1, y: Double(index) * 0.1, width: 0.5, height: 0.05
            ),
            boundingBoxOrigin: .bottomLeft,
            confidence: try Confidence(0.9)
        )
    }
}

private struct FixedRecognizer: TextRecognizer {
    let count: Int
    var text = "synthetic text"

    func recognizeText(
        in pixels: DecodedPixels,
        dimensions: PixelDimensions
    ) async throws -> [OCRObservation] {
        try observations(count: count, text: text)
    }
}

/// Fails the first call, then succeeds.
private final class FlakyRecognizer: TextRecognizer, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    func recognizeText(
        in pixels: DecodedPixels,
        dimensions: PixelDimensions
    ) async throws -> [OCRObservation] {
        let call = lock.withLock { calls += 1; return calls }
        if call == 1 { throw TextRecognitionError.recognitionFailed }
        return try observations(count: 1)
    }
}

/// Holds each recognition (keyed by image width) until released, and records cancellation.
/// Like a slow Vision request that finishes anyway, it returns its result even when cancelled.
private actor GatedRecognizer: TextRecognizer {
    private var pending: [Int: CheckedContinuation<[OCRObservation], Never>] = [:]
    private var requestWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var cancelled: Set<Int> = []

    func recognizeText(
        in pixels: DecodedPixels,
        dimensions: PixelDimensions
    ) async throws -> [OCRObservation] {
        let width = dimensions.width
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pending[width] = continuation
                requestWaiters.removeValue(forKey: width)?.forEach { $0.resume() }
            }
        } onCancel: {
            Task { await self.markCancelled(width) }
        }
    }

    func waitUntilRequested(width: Int) async {
        if pending[width] != nil { return }
        await withCheckedContinuation { requestWaiters[width, default: []].append($0) }
    }

    func wasCancelled(width: Int) async -> Bool {
        // Let the cancellation handler's hop land.
        for _ in 0..<20 where !cancelled.contains(width) { await Task.yield() }
        return cancelled.contains(width)
    }

    func release(width: Int, count: Int) {
        pending.removeValue(forKey: width)?.resume(returning: (try? observations(count: count)) ?? [])
    }

    private func markCancelled(_ width: Int) {
        cancelled.insert(width)
    }
}

/// Returns findings only after a delay, so a newer document can replace this one first.
private struct PendingReviewComposer: CandidateComposer {
    func composeCandidates(
        from detections: [SecretDetection], observations: [OCRObservation],
        pixels: DecodedPixels?, dimensions: PixelDimensions
    ) throws -> [RedactionCandidate] {
        let observation = observations[0]
        return [try RedactionCandidate(
            region: RedactionRegion(rect: ImageRect(x: 0, y: 0, width: 2, height: 2)),
            evidence: DetectionEvidence(ruleID: DetectorRuleID("test.review"),
                                        observationIDs: [observation.id], confidence: Confidence(0.5))
        )]
    }
}

private struct SlowDetector: SecretDetector {
    func detectSecrets(in observations: [OCRObservation]) async throws -> [SecretDetection] {
        try? await Task.sleep(for: .milliseconds(200))
        return ContextualSecretDetector().detect(in: observations)
    }
}

private final class EventSink: PrivacyLogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [PrivacyLogEntry] = []

    var entries: [PrivacyLogEntry] { lock.withLock { stored } }
    var events: [PrivacyLogEvent] { entries.map(\.event) }

    func write(_ entry: PrivacyLogEntry) {
        lock.withLock { stored.append(entry) }
    }
}
