import Foundation
import Observation

/// Non-sensitive description of the open document, safe for presentation.
public struct ImportedDocumentSummary: Equatable, Sendable {
    public let sessionID: UUID
    public let pixelDimensions: PixelDimensions
    public let colorSpace: RenderingColorSpace
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

    @ObservationIgnored private let lifecycle: SecureImageSessionLifecycle
    @ObservationIgnored private let importer: any ImageImporter
    @ObservationIgnored private let textRecognizer: (any TextRecognizer)?
    @ObservationIgnored private var recognitionGeneration = 0
    @ObservationIgnored private var recognitionTask: Task<Void, Never>?
    @ObservationIgnored private let logger: PrivacySafeLogger
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var importTask: Task<Void, Never>?

    public init(
        lifecycle: SecureImageSessionLifecycle,
        importer: any ImageImporter,
        textRecognizer: (any TextRecognizer)? = nil,
        logger: PrivacySafeLogger = PrivacySafeLogger()
    ) {
        self.lifecycle = lifecycle
        self.importer = importer
        self.textRecognizer = textRecognizer
        self.logger = logger
    }

    /// The open document snapshot, including OCR observations once recognized.
    public var activeDocument: RedactionDocument? {
        guard let document, lifecycle.activeSession?.id == document.sessionID else { return nil }
        return lifecycle.activeSession?.redactionDocument
    }

    /// The task running OCR for the open document, if any. Exposed so tests can await it.
    public var currentRecognition: Task<Void, Never>? { recognitionTask }

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
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionGeneration &+= 1
        recognitionStatus = .idle
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
