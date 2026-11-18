import Foundation

/// The only image value that may leave the app: a flattened raster produced by rendering one
/// fully reviewed document revision.
///
/// It can be created only inside RedScreenCore, by `ScreenshotImportController` after rendering,
/// so exporters and the pasteboard writer cannot be handed the source pixels. It records which
/// session and review revision it came from so a stale result is refused after any edit.
public struct FlattenedRedactedImage: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible {
    public let pixels: DecodedPixels
    let sessionID: UUID
    let reviewRevision: Int
    let importGeneration: Int

    init(renderedPixels: DecodedPixels, sessionID: UUID, reviewRevision: Int, importGeneration: Int) {
        self.pixels = renderedPixels
        self.sessionID = sessionID
        self.reviewRevision = reviewRevision
        self.importGeneration = importGeneration
    }

    public var description: String { "FlattenedRedactedImage(<redacted>)" }
    public var debugDescription: String { description }
}

/// Non-sensitive export and copy failures. Cases never carry paths, filenames, or system error
/// text, so they are safe to present and to map to log events.
public enum ImageExportError: Error, Equatable, Sendable {
    /// The image no longer matches the open, fully reviewed document.
    case reviewChanged
    /// The destination exists and replacing it was not confirmed.
    case destinationExists
    case invalidDestination
    case encodingFailed
    case writeFailed
    case clipboardFailed
    case unavailable
}
