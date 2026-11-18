import Foundation

/// The initial detector families. See docs/SECRET_DETECTION.md for examples and rationale.
public enum SecretFamily: String, CaseIterable, Equatable, Hashable, Sendable {
    /// `KEY=value` lines in `.env` files and shell exports whose key names a secret.
    case envAssignment
    /// Passwords, secrets, tokens, and API keys labelled in config, code, tables, or prose.
    case credentialKeyword
    /// `Authorization: Bearer <token>` and other bearer credentials.
    case bearerToken
    /// PEM private key blocks, from the BEGIN line to the END line.
    case privateKey
    /// Passwords (or bare usernames) embedded in connection URLs.
    case connectionString
    /// Well-known provider token formats such as GitHub, Slack, Stripe, and AWS.
    case providerKeyShape
    /// Random-looking values that are only flagged when nearby text says they are secret.
    case highEntropyContextual

    /// Default severity if the finding is genuine.
    public var severity: SecretSeverity {
        switch self {
        case .privateKey: .critical
        case .providerKeyShape, .connectionString, .bearerToken: .high
        case .envAssignment, .credentialKeyword: .high
        case .highEntropyContextual: .medium
        }
    }
}

/// Impact if the value is genuine and exposed.
public enum SecretSeverity: Int, Comparable, CaseIterable, Sendable {
    case low = 0
    case medium = 1
    case high = 2
    case critical = 3

    public static func < (lhs: SecretSeverity, rhs: SecretSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// How sure the detector is. Ambiguous findings are returned for review, never discarded.
public enum DetectionAssessment: Equatable, Sendable {
    /// Confidence at or above `SecretDetectionThresholds.likelyConfidence`.
    case likely
    /// Between the review and likely thresholds: show it, but let the user decide.
    case needsReview
}

/// The location of a sensitive value inside one OCR observation's text.
public struct DetectedTextSpan: Equatable, Hashable, Sendable {
    public let observationID: OCRObservation.ID
    /// UTF-16 offsets into `OCRObservation.text`, covering the value only.
    public let utf16Range: Range<Int>

    public init(observationID: OCRObservation.ID, utf16Range: Range<Int>) {
        self.observationID = observationID
        self.utf16Range = utf16Range
    }
}

/// Every tunable number the detector uses, in one place.
public struct SecretDetectionThresholds: Equatable, Sendable {
    /// Findings at or above this confidence are `likely`.
    public var likelyConfidence: Double
    /// Findings at or above this (and below `likelyConfidence`) are `needsReview`.
    public var reviewConfidence: Double

    /// Keyword weights multiplied by value strength.
    public var strongKeywordWeight: Double
    public var mediumKeywordWeight: Double
    public var weakKeywordWeight: Double

    /// Shortest value considered secret-like.
    public var minimumValueLength: Int
    /// Values at least this long get a strength bonus.
    public var longValueLength: Int
    /// Shannon entropy (bits per character) treated as random-looking.
    public var highEntropyBitsPerCharacter: Double
    /// Shortest value the high-entropy rule considers.
    public var highEntropyMinimumLength: Int

    /// Bounded work: analysis stops after this many observations, characters per observation,
    /// and lines per private key block.
    public var maximumObservations: Int
    public var maximumAnalyzedUTF16PerObservation: Int
    public var maximumPrivateKeyLines: Int

    public static let standard = SecretDetectionThresholds(
        likelyConfidence: 0.7,
        reviewConfidence: 0.35,
        strongKeywordWeight: 1.0,
        mediumKeywordWeight: 0.75,
        weakKeywordWeight: 0.65,
        minimumValueLength: 6,
        longValueLength: 16,
        highEntropyBitsPerCharacter: 3.5,
        highEntropyMinimumLength: 16,
        maximumObservations: 5_000,
        maximumAnalyzedUTF16PerObservation: 2_048,
        maximumPrivateKeyLines: 200
    )

    public func assessment(for confidence: Double) -> DetectionAssessment? {
        if confidence >= likelyConfidence { return .likely }
        if confidence >= reviewConfidence { return .needsReview }
        return nil
    }
}
