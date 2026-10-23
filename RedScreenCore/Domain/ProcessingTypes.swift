import Foundation

/// Opaque in-memory image data passed between pipeline stages.
///
/// The core module deliberately does not interpret or log these bytes.
public struct ScreenshotImage: Equatable, Sendable {
    public let data: Data

    public init(data: Data) {
        self.data = data
    }
}

public struct RecognizedText: Equatable, Sendable {
    public let value: String

    public init(value: String) {
        self.value = value
    }
}

/// Decoded image pixels retained only for the lifetime of an active session.
///
/// The bytes are intentionally represented without an AppKit dependency so a later image decoder
/// can choose its native pixel format while the lifecycle remains testable in RedScreenCore.
public struct DecodedPixels: Equatable, Sendable {
    public let bytes: Data

    public init(bytes: Data) {
        self.bytes = bytes
    }
}

public struct SensitiveRegion: Equatable, Sendable {
    public let identifier: UUID

    public init(identifier: UUID = UUID()) {
        self.identifier = identifier
    }
}

/// A detection result whose candidate value must be treated as secret material.
public struct DetectedSensitiveInformation: Equatable, Sendable {
    public let region: SensitiveRegion
    public let candidateValue: String

    public init(region: SensitiveRegion, candidateValue: String) {
        self.region = region
        self.candidateValue = candidateValue
    }
}

/// One in-memory undo step. Undo history is session-owned and is never autosaved.
public struct RedactionUndoState: Equatable, Sendable {
    public let redactedRegions: [SensitiveRegion]

    public init(redactedRegions: [SensitiveRegion]) {
        self.redactedRegions = redactedRegions
    }
}

public struct ExportDestination: Equatable, Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }
}
