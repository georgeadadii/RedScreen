import Foundation

/// Executable privacy policy for current and future processing components.
public enum ImageLifecyclePolicy {
    public static let processingIsOnDeviceOnly = true
    public static let automaticallyPersistsSourceImages = false
    public static let automaticallyPersistsRecognizedText = false
    public static let automaticallyPersistsDetectedInformation = false
    public static let usesApplicationManagedPlaintextTemporaryImages = false
    public static let registersRecentDocuments = false
    public static let permitsNetworkAccess = false
}

/// All sensitive artifacts owned by one open image document.
///
/// Callers may inspect state for presentation and processing. Mutations are restricted to
/// `SecureImageSessionLifecycle`, which clears every field when the document closes or is replaced.
@MainActor
public final class SecureImageSession {
    public let id: UUID
    public let sourceIdentity: SourceImageIdentity

    public fileprivate(set) var sourceImage: ScreenshotImage?
    public fileprivate(set) var decodedPixels: DecodedPixels?
    public fileprivate(set) var redactionDocument: RedactionDocument?
    public fileprivate(set) var previewImage: ScreenshotImage?
    public fileprivate(set) var clipboardImage: ScreenshotImage?

    fileprivate init(
        id: UUID = UUID(),
        sourceIdentity: SourceImageIdentity,
        sourceImage: ScreenshotImage,
        redactionDocument: RedactionDocument? = nil
    ) {
        self.id = id
        self.sourceIdentity = sourceIdentity
        self.sourceImage = sourceImage
        self.redactionDocument = redactionDocument
    }

    fileprivate func clearSensitiveState() {
        sourceImage = nil
        decodedPixels = nil
        redactionDocument = nil
        previewImage = nil
        clipboardImage = nil
    }
}

/// Owns the sensitive in-memory state for the currently open image document.
///
/// A session identifier must accompany stage updates so work finishing after a replacement cannot
/// populate the new document with artifacts from the old one. This type performs no file I/O.
@MainActor
public final class SecureImageSessionLifecycle {
    public private(set) var activeSession: SecureImageSession?

    private let logger: PrivacySafeLogger

    public init(logger: PrivacySafeLogger = PrivacySafeLogger()) {
        self.logger = logger
    }

    @discardableResult
    public func createSession(
        sourceImage: ScreenshotImage,
        sourceIdentity: SourceImageIdentity = SourceImageIdentity()
    ) -> SecureImageSession {
        let event: PrivacyLogEvent
        if let activeSession {
            activeSession.clearSensitiveState()
            event = .sessionReplaced
        } else {
            event = .sessionCreated
        }

        let session = SecureImageSession(
            sourceIdentity: sourceIdentity,
            sourceImage: sourceImage
        )
        activeSession = session
        logger.record(event)
        return session
    }

    @discardableResult
    public func createSession(importedImage: ImportedImage) throws -> SecureImageSession {
        let document = try RedactionDocument(
            sourceIdentity: importedImage.sourceIdentity,
            pixelDimensions: importedImage.pixelDimensions
        )
        let event: PrivacyLogEvent
        if let activeSession {
            activeSession.clearSensitiveState()
            event = .sessionReplaced
        } else {
            event = .sessionCreated
        }
        let session = SecureImageSession(
            sourceIdentity: importedImage.sourceIdentity,
            sourceImage: importedImage.image,
            redactionDocument: document
        )
        activeSession = session
        logger.record(event)
        return session
    }

    public func reset() {
        guard let activeSession else { return }
        activeSession.clearSensitiveState()
        self.activeSession = nil
        logger.record(.sessionReset)
    }

    public func closeDocument() {
        reset()
    }

    @discardableResult
    public func storeDecodedPixels(_ pixels: DecodedPixels, for sessionID: UUID) -> Bool {
        guard let session = session(matching: sessionID) else { return false }
        session.decodedPixels = pixels
        logger.record(.pixelsDecoded)
        return true
    }

    @discardableResult
    public func storeDocument(_ document: RedactionDocument, for sessionID: UUID) -> Bool {
        guard let session = session(matching: sessionID) else { return false }
        guard document.sourceIdentity == session.sourceIdentity else { return false }
        session.redactionDocument = document
        logger.record(.documentUpdated)
        return true
    }

    @discardableResult
    public func storePreview(_ image: ScreenshotImage, for sessionID: UUID) -> Bool {
        guard let session = session(matching: sessionID) else { return false }
        session.previewImage = image
        logger.record(.previewUpdated)
        return true
    }

    @discardableResult
    public func storeClipboardImage(_ image: ScreenshotImage, for sessionID: UUID) -> Bool {
        guard let session = session(matching: sessionID) else { return false }
        session.clipboardImage = image
        logger.record(.clipboardPrepared)
        return true
    }

    private func session(matching id: UUID) -> SecureImageSession? {
        guard activeSession?.id == id else { return nil }
        return activeSession
    }
}
