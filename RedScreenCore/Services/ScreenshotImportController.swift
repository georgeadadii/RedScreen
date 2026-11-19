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

/// Why the workflow stopped. Non-sensitive: no paths, text, or system error descriptions.
public enum WorkflowFailure: Equatable, Sendable {
    /// Import failed and no document is open. With a document open, the failure is shown as
    /// `lastError` and the document keeps its own state.
    case importFailed(ImageImportError)
    /// Capture failed and no document is open.
    case captureFailed(CaptureError)
    case recognitionFailed(TextRecognitionError)
    case detectionFailed
}

/// The single, explicit state of the import-to-export workflow, derived from the controller's
/// stage tokens so it can never disagree with them.
///
/// Transitions:
/// - `idle` → `loading` on import. `loading` → `recognizing` once the image decodes, `failed`
///   if it does not (or back to the open document's state), `canceled` on cancel.
/// - `recognizing` covers OCR, detection, and candidate composition. It ends in `reviewing`,
///   `failed`, or `canceled`; `retryRecognition()` restarts it from `failed` or `canceled`.
/// - `reviewing` → `rendering` while a reviewed render is in flight, and → `exporting` while a
///   save is in flight. Both return to `reviewing`.
/// - Any state → `idle` on close. A new import from any state → `loading`; results of the
///   superseded work are discarded.
public enum WorkflowState: Equatable, Sendable {
    case idle
    case loading
    case recognizing
    case reviewing
    case rendering
    case exporting
    case failed(WorkflowFailure)
    case canceled
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
    /// The last recoverable capture failure. Cancellation is never reported here.
    public private(set) var lastCaptureError: CaptureError?
    public private(set) var recognitionStatus: TextRecognitionStatus = .idle
    public private(set) var detectionStatus: SecretDetectionStatus = .idle

    public private(set) var reviewRevision = 0
    private var undoHistory: [RedactionDocument] = []
    private var redoHistory: [RedactionDocument] = []
    private let reviewHistoryLimit = 100

    @ObservationIgnored private let lifecycle: SecureImageSessionLifecycle
    @ObservationIgnored private let importer: any ImageImporter
    @ObservationIgnored private let screenCapturer: (any ScreenCaptureService)?
    @ObservationIgnored private let textRecognizer: (any TextRecognizer)?
    @ObservationIgnored private let secretDetector: (any SecretDetector)?
    @ObservationIgnored private let candidateComposer: (any CandidateComposer)?
    public private(set) var processingCanceled = false
    private var activeRenders = 0
    private var activeExports = 0

    @ObservationIgnored private let renderer: any RedactionRenderer
    @ObservationIgnored private let imageExporter: (any ImageExporter)?
    @ObservationIgnored private let clipboard: (any RedactedImageClipboard)?
    @ObservationIgnored private var detectionTask: Task<Void, Never>?
    @ObservationIgnored private var recognitionGeneration = 0
    @ObservationIgnored private var recognitionTask: Task<Void, Never>?
    @ObservationIgnored private let logger: PrivacySafeLogger
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var importTask: Task<Void, Never>?
    /// When the current load started, for the capture-to-review measurement.
    @ObservationIgnored private var loadStartedAt: ContinuousClock.Instant?
    /// The captured session whose time to review has not been recorded yet.
    @ObservationIgnored private var pendingReviewTiming: (sessionID: UUID, startedAt: ContinuousClock.Instant)?

    public init(
        lifecycle: SecureImageSessionLifecycle,
        importer: any ImageImporter,
        screenCapturer: (any ScreenCaptureService)? = nil,
        textRecognizer: (any TextRecognizer)? = nil,
        secretDetector: (any SecretDetector)? = nil,
        candidateComposer: (any CandidateComposer)? = nil,
        renderer: any RedactionRenderer = SolidFillRedactionRenderer(),
        imageExporter: (any ImageExporter)? = nil,
        clipboard: (any RedactedImageClipboard)? = nil,
        logger: PrivacySafeLogger = PrivacySafeLogger()
    ) {
        self.candidateComposer = candidateComposer
        self.renderer = renderer
        self.imageExporter = imageExporter
        self.clipboard = clipboard
        self.lifecycle = lifecycle
        self.importer = importer
        self.screenCapturer = screenCapturer
        self.textRecognizer = textRecognizer
        self.secretDetector = secretDetector
        self.logger = logger
    }

    public var workflowState: WorkflowState {
        if isImporting { return .loading }
        guard document != nil else {
            if let lastError { return .failed(.importFailed(lastError)) }
            if let lastCaptureError { return .failed(.captureFailed(lastCaptureError)) }
            return processingCanceled ? .canceled : .idle
        }
        if activeExports > 0 { return .exporting }
        if activeRenders > 0 { return .rendering }
        if processingCanceled { return .canceled }
        if case .failed(let error) = recognitionStatus { return .failed(.recognitionFailed(error)) }
        if detectionStatus == .failed { return .failed(.detectionFailed) }
        return canReview ? .reviewing : .recognizing
    }

    /// Whether `cancelProcessing()` has anything to stop.
    public var canCancelProcessing: Bool {
        workflowState == .loading || workflowState == .recognizing
    }

    /// Stops an in-flight import or recognition/detection pass.
    ///
    /// Cancelling an import keeps the open document, if any, untouched. Cancelling recognition
    /// leaves the document open with no findings, in `canceled`, until `retryRecognition()`.
    /// Late results from the cancelled work are discarded.
    public func cancelProcessing() {
        if isImporting {
            importTask?.cancel()
            importTask = nil
            generation &+= 1
            isImporting = false
            if document == nil { processingCanceled = true }
            logger.record(.processingCanceled)
            return
        }
        guard workflowState == .recognizing, let id = document?.sessionID else { return }
        cancelRecognition()
        if let current = activeDocument,
           let cleared = try? current.replacingObservations([], processingState: .imported) {
            lifecycle.storeDocument(cleared, for: id)
        }
        processingCanceled = true
        logger.record(.processingCanceled)
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
        activeRenders += 1
        defer { activeRenders -= 1 }
        let result = try await renderer.render(document: current, sourceImage: pixels)
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
        activeExports += 1
        defer { activeExports -= 1 }
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
        let importer = importer
        return startLoading(.imported) { try await importer.importImage(from: url) }
    }

    public var canCaptureScreenshots: Bool { screenCapturer != nil }

    /// Captures a user-chosen region, window, or display into a new document, through the same
    /// path as an import: the open document is replaced only on success, a canceled capture
    /// leaves everything as it was, and a newer import or capture supersedes this one.
    @discardableResult
    public func captureScreenshot(_ target: CaptureTarget) -> Task<Void, Never>? {
        guard let screenCapturer else { return nil }
        return startLoading(.captured) { try await screenCapturer.capture(target) }
    }

    /// Records a capture that ended before the capture service ran, such as an empty region
    /// selection or a display change during selection. Cancellation is not reported.
    public func reportCaptureFailure(_ error: CaptureError) {
        guard error != .canceled else { return }
        lastCaptureError = error
        logger.record(.captureFailed)
    }

    private enum LoadSource { case imported, captured }

    private func startLoading(
        _ source: LoadSource,
        _ work: @escaping @Sendable () async throws -> ImportedImage
    ) -> Task<Void, Never> {
        importTask?.cancel()
        generation &+= 1
        let token = generation
        isImporting = true
        lastError = nil
        lastCaptureError = nil
        loadStartedAt = ContinuousClock.now
        if document == nil { processingCanceled = false }

        let task = Task { [weak self] in
            let result: Result<ImportedImage, any Error>
            do {
                result = .success(try await work())
            } catch {
                result = .failure(error)
            }
            self?.finishImport(result, source: source, token: token)
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
        lastCaptureError = nil
        processingCanceled = false
        document = nil
        lifecycle.closeDocument()
    }

    public func dismissError() {
        lastError = nil
        lastCaptureError = nil
    }

    /// Runs text recognition again on the open document, for example after a failure.
    @discardableResult
    public func retryRecognition() -> Task<Void, Never>? {
        guard let session = lifecycle.activeSession, session.id == document?.sessionID else {
            return nil
        }
        return startRecognition(for: session)
    }

    private func finishImport(_ result: Result<ImportedImage, any Error>, source: LoadSource, token: Int) {
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
                logger.record(source == .captured ? .screenCaptured : .imageImported)
                pendingReviewTiming = source == .captured ? loadStartedAt.map { (session.id, $0) } : nil
                startRecognition(for: session)
            } catch {
                reject(error as? ImageImportError ?? .corruptImage)
            }
        case .failure(let error):
            if error is CancellationError { return }
            if source == .captured {
                reportCaptureFailure(error as? CaptureError ?? .failed)
                return
            }
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
        processingCanceled = false
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
            recordCaptureToReview(sessionID: sessionID)
        case .failure(let error):
            if error is CancellationError {
                detectionStatus = .idle
                return
            }
            failDetection(current: current, sessionID: sessionID)
        }
    }

    /// Records how long a capture took to become reviewable, and the process memory footprint at
    /// that moment, as numbers only. Recorded once per captured session.
    private func recordCaptureToReview(sessionID: UUID) {
        guard let pending = pendingReviewTiming, pending.sessionID == sessionID else { return }
        pendingReviewTiming = nil
        let elapsed = ContinuousClock.now - pending.startedAt
        let milliseconds = elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000
        logger.record(.captureToReviewDuration, count: UInt(max(0, milliseconds)))
        logger.record(.memoryFootprint, count: UInt(ProcessMemory.footprintBytes() / 1_048_576))
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
