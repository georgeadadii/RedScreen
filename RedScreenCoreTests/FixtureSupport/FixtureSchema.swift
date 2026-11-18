import Foundation

// SYNTHETIC TEST DATA SCHEMA.
//
// This file is compiled into both the RedScreenCoreTests bundle and the standalone fixture
// generator (`make fixtures`). It must depend only on Foundation so the generator can be built
// without RedScreenCore. Every credential-like value described by this schema is fake.

enum FixtureSchema {
    static let version = 1
    static let coordinateSpace = "normalized-top-left"
    static let notice =
        "Synthetic RedScreen test data. Every credential-like value is fake and reserved for tests."
}

/// The initial detector families from issue #7 that every fixture span is labelled with.
enum FixtureSecretFamily: String, Codable, CaseIterable, Sendable {
    case envAssignment
    case credentialKeyword
    case bearerToken
    case privateKeyHeader
    case connectionString
    case providerKeyShape
    case highEntropyContextual
}

/// What a correct pipeline must do with a labelled span.
enum FixtureExpectation: String, Codable, CaseIterable, Sendable {
    /// Must be redacted. Missing it is a false negative.
    case sensitive
    /// Looks credential-like but must not be redacted. Redacting it is a false positive.
    case benign
    /// Reasonable people disagree; it should surface for review but is never scored either way.
    case ambiguous
}

enum FixtureCategory: String, Codable, CaseIterable, Sendable {
    case envFile
    case terminal
    case jsonConfig
    case yamlConfig
    case ciLog
    case dashboard
    case benignCode
}

enum FixtureTheme: String, Codable, CaseIterable, Sendable {
    case light
    case dark
    case lowContrast
}

enum FixtureFontStyle: String, Codable, CaseIterable, Sendable {
    case monospace
    case proportional
}

enum FixtureDifficulty: String, Codable, CaseIterable, Sendable {
    case wrappedValue
    case multiColumn
    case punctuation
    case nearbyBenign
    case quotedValue
    case multilineBlock
    /// Code-editor rendering: line-number gutter, syntax colours, tight line spacing.
    case editorChrome
    /// Secrets on directly adjacent lines.
    case adjacentSecrets
}

/// A rectangle in normalized, top-left-origin image coordinates.
struct FixtureRect: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

/// One rendered line or table cell. Text boxes are the OCR-level ground truth.
struct FixtureTextBox: Codable, Equatable, Sendable {
    let id: String
    let text: String
    let rect: FixtureRect
}

/// The part of a span that lies inside one text box. Offsets are UTF-16 code units into the box
/// text so they map directly onto `NSRange` and Core Text string indices.
struct FixtureSpanSegment: Codable, Equatable, Sendable {
    let textBoxID: String
    let utf16Offset: Int
    let utf16Length: Int
    let rect: FixtureRect
}

/// A labelled value. Wrapped or multi-line values have one segment per text box.
struct FixtureSpan: Codable, Equatable, Sendable {
    let id: String
    let family: FixtureSecretFamily
    let expectation: FixtureExpectation
    /// Short non-sensitive rationale. It never repeats the value.
    let note: String
    let segments: [FixtureSpanSegment]
}

struct FixtureGroundTruth: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let id: String
    let scenario: String
    let syntheticTestData: Bool
    let category: FixtureCategory
    let theme: FixtureTheme
    let fontStyle: FixtureFontStyle
    let scale: Int
    let difficulties: [FixtureDifficulty]
    let pixelWidth: Int
    let pixelHeight: Int
    let coordinateSpace: String
    let textBoxes: [FixtureTextBox]
    let spans: [FixtureSpan]
}

struct FixtureManifestEntry: Codable, Equatable, Sendable {
    let id: String
    let image: String
    let groundTruth: String
    let imageSHA256: String
    let groundTruthSHA256: String
}

struct FixtureManifest: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let notice: String
    let entries: [FixtureManifestEntry]
}

enum FixtureJSON {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        JSONDecoder()
    }
}
