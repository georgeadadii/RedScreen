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

public struct SensitiveRegion: Equatable, Sendable {
    public let identifier: UUID

    public init(identifier: UUID = UUID()) {
        self.identifier = identifier
    }
}

public struct ExportDestination: Equatable, Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }
}
