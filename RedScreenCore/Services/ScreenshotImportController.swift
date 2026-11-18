import Foundation
import Observation

/// Non-sensitive description of the open document, safe for presentation.
public struct ImportedDocumentSummary: Equatable, Sendable {
    public let sessionID: UUID
    public let pixelDimensions: PixelDimensions
    public let colorSpace: RenderingColorSpace
}

public enum ReviewRenderError: Error, Equatable, Sendable {
    case reviewRequired
}

/// Coordinates user-initiated imports with the secure image lifecycle.
///
/// - The current document is replaced only after the new image decodes successfully. Failures
///   leave the open document and its session untouched and surface `lastError`.
/// - Each import gets a generation token. Starting another import or closing the document
///   cancels the previous work, and any result that arrives later is discarded.
/// - Pixels are never retained here; `activePixels` reads through to the active session.
/// - After a successful import, text recognition runs on the new session. It is cancelled when
///   another document replaces this one or the document closes, and a result is stored only if
///   its session is still active. A failed import does not interrupt the open document's OCR.
@MainActor
@Observable
public final class ScreenshotImportController {
    public private(set) var document: ImportedDocumentSummary?
    public private(set) var isImporting = false
    public private(set) var lastError: ImageImportError?
    public private(set) var recognitionStatus: TextRecognitionStatus = .idle
    public private(set) var detectionStatus: SecretDetectionStatus = .idle

    public private(set) var reviewRevision = 0
    private var undoHistory: [RedactionDocument] = []
    private var redoHistory: [RedactionDocument] = []
    private let reviewHistoryLimit = 100

    @ObservationIgnored private let lifecycle: SecureImageSessionLifecycle
    @ObservationIgnored private let importer: any ImageImporter
    @ObservationIgnored private let textRecognizer: (any TextRecognizer)?
    @ObservationIgnored private let secretDetector: (any SecretDetector)?
    @ObservationIgnored private let candidateComposer: (any CandidateComposer)?
    @ObservationIgnored private let imageExporter: (any ImageExporter)?
    @ObservationIgnored private let clipboard: (any RedactedImageClipboard)?
    @ObservationIgnored private var detectionTask: Task<Void, Never>?
    @ObservationIgnored private var recognitionGeneration = 0
    @ObservationIgnored private var recognitionTask: Task<Void, Never>?
    @ObservationIgnored private let logger: PrivacySafeLogger
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var importTask: Task<Void, Never>?

    public init(
        lifecycle: SecureImageSessionLifecycle,
        importer: any ImageImporter,
        textRecognizer: (any TextRecognizer)? = nil,
        secretDetector: (any SecretDetector)? = nil,
        candidateComposer: (any CandidateComposer)? = nil,
        imageExporter: (any ImageExporter)? = nil,
        clipboard: (any RedactedImageClipboard)? = nil,
        logger: PrivacySafeLogger = PrivacySafeLogger()
    ) {
        self.candidateComposer = candidateComposer
        self.imageExporter = imageExporter
        self.clipboard = clipboard
        self.lifecycle = lifecycle
        self.importer = importer
        self.textRecognizer = textRecognizer
        self.secretDetector = secretDetector
        self.logger = logger
    }

    /// The open document snapshot, including OCR observations once recognized.
    public var activeDocument: RedactionDocument? {
        _ = reviewRevision // Observe edits while the secure session owns the current document.
        guard let document, lifecycle.activeSession?.id == document.sessionID else { return nil }
        return lifecycle.activeSession?.redactionDocument
    }

    public var canReview: Bool { !isImporting && activeDocument?.processingState == .readyForReview }
    public var pendingReviewCount: Int {
        activeDocument?.candidates.count(where: { $0.disposition == .pending }) ?? 0
    }
    public var canRenderReviewedImage: Bool { canReview && pendingReviewCount == 0 }
    public var canUndoReview: Bool { canReview && !undoHistory.isEmpty }
    public var canRedoReview: Bool { canReview && !redoHistory.isEmpty }

    @discardableResult
    public func setReviewDisposition(_ disposition: RedactionDisposition, for id: UUID) -> Bool {
        guard disposition == .included || disposition == .excluded else { return false }
        return applyReviewEdit { snapshot in
            guard snapshot.candidates.first(where: { $0.id == id })?.disposition != disposition else {
                return snapshot
            }
            return try snapshot.settingDisposition(disposition, for: id)
        }
    }

    @discardableResult
    public func addManualRedaction(_ rect: ImageRect) -> UUID? {
        let id = UUID()
        return applyReviewEdit { try $0.addingManualRegion(RedactionRegion(rect: rect), candidateID: id) }
            ? id : nil
    }

    @discardableResult
    public func updateManualRedaction(_ id: UUID, rect: ImageRect) -> Bool {
        applyReviewEdit { try $0.updatingManualRegion(rect, for: id) }
    }

    @discardableResult
    public func deleteManualRedaction(_ id: UUID) -> Bool {
        applyReviewEdit { try $0.removingManualCandidate(id) }
    }

    public func undoReview() {
        guard canUndoReview, let previous = undoHistory.last, let current = activeDocument,
              let id = document?.sessionID, storeReviewDocument(previous, id: id) else { return }
        undoHistory.removeLast()
        redoHistory.append(current)
    }

    public func redoReview() {
        guard canRedoReview, let next = redoHistory.last, let current = activeDocument,
              let id = document?.sessionID, storeReviewDocument(next, id: id) else { return }
        redoHistory.removeLast()
        undoHistory.append(current)
    }

    /// Returns only a flattened raster from the current reviewed revision. An edit, import, or
    /// session replacement while rendering invalidates the result.
    public func renderReviewedImage() async throws -> FlattenedRedactedImage {
        guard canRenderReviewedImage, let current = activeDocument, let pixels = activePixels,
              let sessionID = document?.sessionID else { throw ReviewRenderError.reviewRequired }
        let revision = reviewRevision
        let importGeneration = generation
        let result = try await SolidFillRedactionRenderer().render(document: current, sourceImage: pixels)
        try Task.checkCancellation()
        guard document?.sessionID == sessionID, revision == reviewRevision,
              importGeneration == generation, canRenderReviewedImage else { throw CancellationError() }
        return FlattenedRedactedImage(
            renderedPixels: result,
            sessionID: sessionID,
            reviewRevision: revision,
            importGeneration: importGeneration
        )
    }

    /// Whether `image` was rendered from the open document's current, fully reviewed revision.
    public func isCurrentReviewedImage(_ image: FlattenedRedactedImage) -> Bool {
        canRenderReviewedImage && image.sessionID == document?.sessionID
            && image.reviewRevision == reviewRevision && image.importGeneration == generation
    }

    /// Saves exactly `image`, the flattened render the user reviewed, to a user-selected file.
    /// Refuses a render made before the latest edit, import, or close.
    public func exportReviewedImage(
        _ image: FlattenedRedactedImage,
        to destination: ExportDestination
    ) async throws {
        guard let imageExporter else { throw ImageExportError.unavailable }
        guard isCurrentReviewedImage(image) else { throw ImageExportError.reviewChanged }
        do {
            try await imageExporter.export(image, to: destination)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.record(.redactedImageSaveFailed)
            throw error as? ImageExportError ?? .writeFailed
        }
        logger.record(.redactedImageSaved)
    }

    /// Copies exactly `image` to the clipboard as rendered image data only.
    public func copyReviewedImage(_ image: FlattenedRedactedImage) throws {
        guard let clipboard else { throw ImageExportError.unavailable }
        guard isCurrentReviewedImage(image) else { throw ImageExportError.reviewChanged }
        do {
            try clipboard.copy(image)
        } catch {
            logger.record(.redactedImageCopyFailed)
            throw error as? ImageExportError ?? .clipboardFailed
        }
        logger.record(.redactedImageCopied)
    }

    private func applyReviewEdit(_ edit: (RedactionDocument) throws -> RedactionDocument) -> Bool {
        guard canReview, let current = activeDocument, let id = document?.sessionID,
              let next = try? edit(current), next != current,
              storeReviewDocument(next, id: id) else { return false }
        undoHistory.append(current)
        if undoHistory.count > reviewHistoryLimit { undoHistory.removeFirst() }
        redoHistory.removeAll()
        return true
    }

    private func storeReviewDocument(_ snapshot: RedactionDocument, id: UUID) -> Bool {
        guard lifecycle.storeDocument(snapshot, for: id) else { return false }
        reviewRevision &+= 1
        return true
    }

    private func resetReviewHistory() {
        undoHistory.removeAll()
        redoHistory.removeAll()
        reviewRevision &+= 1
    }

    /// The task running OCR for the open document, if any. Exposed so tests can await it.
    public var currentRecognition: Task<Void, Never>? { recognitionTask }

    /// The task running secret detection for the open document, if any.
    public var currentDetection: Task<Void, Never>? { detectionTask }

    /// The open document's normalized pixels, owned by the active session.
    public var activePixels: DecodedPixels? {
        guard let document, lifecycle.activeSession?.id == document.sessionID else { return nil }
        return lifecycle.activeSession?.decodedPixels
    }

    /// Starts importing a user-selected file. The returned task completes once the result has
    /// been applied or discarded.
    @discardableResult
    public func importImage(from url: URL) -> Task<Void, Never> {
        importTask?.cancel()
        generation &+= 1
        let token = generation
        isImporting = true
        lastError = nil

        let importer = importer
        let task = Task { [weak self] in
            let result: Result<ImportedImage, any Error>
            do {
                result = .success(try await importer.importImage(from: url))
            } catch {
                result = .failure(error)
            }
            self?.finishImport(result, token: token)
        }
        importTask = task
        return task
    }

    /// Imports a drag-and-drop payload, which must be exactly one file URL.
    @discardableResult
    public func importDroppedItems(_ urls: [URL]) -> Task<Void, Never>? {
        guard urls.count == 1, let url = urls.first else {
            reject(urls.isEmpty ? .notAFile : .multipleItems)
            return nil
        }
        guard url.isFileURL else {
            reject(.notAFile)
            return nil
        }
        return importImage(from: url)
    }

    /// Closes the document, clears every session artifact, and abandons in-flight imports.
    public func closeDocument() {
        importTask?.cancel()
        importTask = nil
        generation &+= 1
        cancelRecognition()
        isImporting = false
        lastError = nil
        document = nil
        lifecycle.closeDocument()
    }

    public func dismissError() {
        lastError = nil
    }

    /// Runs text recognition again on the open document, for example after a failure.
    @discardableResult
    public func retryRecognition() -> Task<Void, Never>? {
        guard let session = lifecycle.activeSession, session.id == document?.sessionID else {
            return nil
        }
        return startRecognition(for: session)
    }

    private func finishImport(_ result: Result<ImportedImage, any Error>, token: Int) {
        // A newer import or a close superseded this one; drop the result and its pixels.
        guard token == generation else { return }
        isImporting = false
        importTask = nil

        switch result {
        case .success(let imported):
            do {
                let session = try lifecycle.createSession(importedImage: imported)
                cancelRecognition()
                document = ImportedDocumentSummary(
                    sessionID: session.id,
                    pixelDimensions: imported.pixelDimensions,
                    colorSpace: imported.pixels.layout?.colorSpace ?? .sRGB
                )
                logger.record(.imageImported)
                startRecognition(for: session)
            } catch {
                reject(error as? ImageImportError ?? .corruptImage)
            }
        case .failure(let error):
            if error is CancellationError { return }
            reject(error as? ImageImportError ?? .unreadable)
        }
    }

    // MARK: - Text recognition

    @discardableResult
    private func startRecognition(for session: SecureImageSession) -> Task<Void, Never>? {
        guard let textRecognizer,
              let pixels = session.decodedPixels,
              let current = session.redactionDocument else {
            return nil
        }
        cancelRecognition()
        let token = recognitionGeneration
        let sessionID = session.id
        let dimensions = current.pixelDimensions
        recognitionStatus = .recognizing
        if let recognizing = try? current.replacingObservations(
            [], processingState: .recognizingText
        ) {
            lifecycle.storeDocument(recognizing, for: sessionID)
        }

        let task = Task { [weak self] in
            let clock = ContinuousClock()
            let start = clock.now
            let result: Result<[OCRObservation], any Error>
            do {
                result = .success(
                    try await textRecognizer.recognizeText(in: pixels, dimensions: dimensions)
                )
            } catch {
                result = .failure(error)
            }
            self?.finishRecognition(
                result, token: token, sessionID: sessionID, elapsed: clock.now - start
            )
        }
        recognitionTask = task
        return task
    }

    private func cancelRecognition() {
        resetReviewHistory()
        recognitionTask?.cancel()
        recognitionTask = nil
        detectionTask?.cancel()
        detectionTask = nil
        recognitionGeneration &+= 1
        recognitionStatus = .idle
        detectionStatus = .idle
    }

    private func finishRecognition(
        _ result: Result<[OCRObservation], any Error>,
        token: Int,
        sessionID: UUID,
        elapsed: Duration
    ) {
        // Superseded, closed, or replaced: discard without touching the active document.
        guard token == recognitionGeneration,
              let session = lifecycle.activeSession, session.id == sessionID,
              let current = session.redactionDocument else {
            return
        }
        recognitionTask = nil
        let milliseconds = UInt(max(0, elapsed.components.seconds * 1_000
            + elapsed.components.attoseconds / 1_000_000_000_000_000))

        switch result {
        case .success(let observations):
            do {
                let recognized = try current.replacingObservations(
                    observations, processingState: .textRecognized
                )
                lifecycle.storeDocument(recognized, for: sessionID)
                recognitionStatus = .recognized(observationCount: observations.count)
                logger.record(.textRecognized, count: UInt(observations.count))
                logger.record(.textRecognitionDuration, count: milliseconds)
                startDetection(observations, token: token, sessionID: sessionID)
            } catch {
                failRecognition(.recognitionFailed, current: current, sessionID: sessionID)
            }
        case .failure(let error):
            if error is CancellationError {
                recognitionStatus = .idle
                return
            }
            failRecognition(
                error as? TextRecognitionError ?? .recognitionFailed,
                current: current,
                sessionID: sessionID
            )
        }
    }

    // MARK: - Secret detection

    private func startDetection(_ observations: [OCRObservation], token: Int, sessionID: UUID) {
        guard let secretDetector else { return }
        detectionStatus = .detecting
        if let session = lifecycle.activeSession, session.id == sessionID,
           let current = session.redactionDocument,
           let detecting = try? current.replacingDetections([], processingState: .detectingSecrets) {
            lifecycle.storeDocument(detecting, for: sessionID)
        }
        detectionTask = Task { [weak self] in
            let result: Result<[SecretDetection], any Error>
            do {
                result = .success(try await secretDetector.detectSecrets(in: observations))
            } catch {
                result = .failure(error)
            }
            self?.finishDetection(result, token: token, sessionID: sessionID)
        }
    }

    private func finishDetection(
        _ result: Result<[SecretDetection], any Error>,
        token: Int,
        sessionID: UUID
    ) {
        guard token == recognitionGeneration,
              let session = lifecycle.activeSession, session.id == sessionID,
              let current = session.redactionDocument else {
            return
        }
        detectionTask = nil
        switch result {
        case .success(let detections):
            guard var detected = try? current.replacingDetections(detections) else {
                failDetection(current: current, sessionID: sessionID)
                return
            }
            if let candidateComposer {
                // Composition is synchronous, bounded geometry work on already-known findings.
                guard let candidates = try? candidateComposer.composeCandidates(
                    from: detections,
                    observations: detected.observations,
                    pixels: session.decodedPixels,
                    dimensions: detected.pixelDimensions
                ), let composed = try? detected.replacingCandidates(candidates) else {
                    failDetection(current: current, sessionID: sessionID)
                    return
                }
                detected = composed
                logger.record(.candidatesComposed, count: UInt(candidates.count))
            }
            lifecycle.storeDocument(detected, for: sessionID)
            let likely = detections.filter { $0.assessment == .likely }.count
            let review = detections.count - likely
            detectionStatus = .detected(likely: likely, needsReview: review)
            logger.record(.sensitiveInformationDetected, count: UInt(likely))
            logger.record(.detectionsNeedingReview, count: UInt(review))
        case .failure(let error):
            if error is CancellationError {
                detectionStatus = .idle
                return
            }
            failDetection(current: current, sessionID: sessionID)
        }
    }

    private func failDetection(current: RedactionDocument, sessionID: UUID) {
        detectionStatus = .failed
        if let failed = try? current.replacingDetections(
            [], processingState: .failed(.detectionFailed)
        ) {
            lifecycle.storeDocument(failed, for: sessionID)
        }
        logger.record(.secretDetectionFailed)
    }

    private func failRecognition(
        _ error: TextRecognitionError,
        current: RedactionDocument,
        sessionID: UUID
    ) {
        recognitionStatus = .failed(error)
        if let failed = try? current.replacingObservations(
            [], processingState: .failed(.recognitionFailed)
        ) {
            lifecycle.storeDocument(failed, for: sessionID)
        }
        logger.record(.textRecognitionFailed)
    }

    private func reject(_ error: ImageImportError) {
        lastError = error
        logger.record(.importRejected)
    }
}
