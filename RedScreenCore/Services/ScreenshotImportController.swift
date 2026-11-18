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
@MainActor
@Observable
public final class ScreenshotImportController {
    public private(set) var document: ImportedDocumentSummary?
    public private(set) var isImporting = false
    public private(set) var lastError: ImageImportError?

    @ObservationIgnored private let lifecycle: SecureImageSessionLifecycle
    @ObservationIgnored private let importer: any ImageImporter
    @ObservationIgnored private let logger: PrivacySafeLogger
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var importTask: Task<Void, Never>?

    public init(
        lifecycle: SecureImageSessionLifecycle,
        importer: any ImageImporter,
        logger: PrivacySafeLogger = PrivacySafeLogger()
    ) {
        self.lifecycle = lifecycle
        self.importer = importer
        self.logger = logger
    }

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
        isImporting = false
        lastError = nil
        document = nil
        lifecycle.closeDocument()
    }

    public func dismissError() {
        lastError = nil
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
                document = ImportedDocumentSummary(
                    sessionID: session.id,
                    pixelDimensions: imported.pixelDimensions,
                    colorSpace: imported.pixels.layout?.colorSpace ?? .sRGB
                )
                logger.record(.imageImported)
            } catch {
                reject(error as? ImageImportError ?? .corruptImage)
            }
        case .failure(let error):
            if error is CancellationError { return }
            reject(error as? ImageImportError ?? .unreadable)
        }
    }

    private func reject(_ error: ImageImportError) {
        lastError = error
        logger.record(.importRejected)
    }
}
