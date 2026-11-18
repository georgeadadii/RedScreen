import Foundation

/// Why text recognition failed. Cases carry no recognized text or image data.
public enum TextRecognitionError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The pixels lack a layout or disagree with the document's dimensions.
    case invalidImage
    /// Vision reported an error while recognizing text.
    case recognitionFailed

    public var userMessage: String {
        switch self {
        case .invalidImage:
            "Text recognition couldn't read this image. Try importing it again."
        case .recognitionFailed:
            "Text recognition failed. You can retry, or continue and mark regions by hand."
        }
    }

    public var description: String {
        switch self {
        case .invalidImage: "invalidImage"
        case .recognitionFailed: "recognitionFailed"
        }
    }
}

/// Presentation state for OCR on the open document. Contains counts only.
public enum TextRecognitionStatus: Equatable, Sendable {
    case idle
    case recognizing
    case recognized(observationCount: Int)
    case failed(TextRecognitionError)
}

/// Presentation state for secret detection on the open document. Counts only.
public enum SecretDetectionStatus: Equatable, Sendable {
    case idle
    case detecting
    case detected(likely: Int, needsReview: Int)
    case failed
}
