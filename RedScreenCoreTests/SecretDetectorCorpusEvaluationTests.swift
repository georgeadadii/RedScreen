import Foundation
import XCTest

@testable import RedScreenCore

/// Measures detector precision and recall on the synthetic corpus (issue #7).
///
/// Two inputs are evaluated:
/// - **Ground-truth text**: each fixture text box becomes an observation, isolating the
///   detector from OCR errors.
/// - **Vision OCR**: the real recognizer's output, end to end.
///
/// Reports print fixture IDs, span IDs, rule IDs, and counts only.
final class SecretDetectorCorpusEvaluationTests: XCTestCase {
    // Targets, documented in docs/SECRET_DETECTION.md.
    static let groundTruthSensitiveRecall = 1.0
    static let groundTruthLikelyRecall = 0.9
    static let groundTruthPrecision = 0.9
    static let groundTruthAmbiguousSurfaced = 0.8
    static let groundTruthMaximumBenignHits = 0
    static let minimumValueOverlap = 0.8
    static let visionSensitiveRecall = 0.85
    static let visionPrecision = 0.85

    struct Tally {
        var sensitive = 0
        var sensitiveFound = 0
        var sensitiveLikely = 0
        var ambiguous = 0
        var ambiguousSurfaced = 0
        var benignHits: [String] = []
        var detections = 0
        var relevantDetections = 0
        var unexpected: [String] = []
        var missed: [String] = []
        var imprecise: [String] = []

        var recall: Double { ratio(sensitiveFound, sensitive) }
        var likelyRecall: Double { ratio(sensitiveLikely, sensitive) }
        var precision: Double { ratio(relevantDetections, detections) }
        var ambiguousRate: Double { ratio(ambiguousSurfaced, ambiguous) }

        private func ratio(_ a: Int, _ b: Int) -> Double { b == 0 ? 1 : Double(a) / Double(b) }

        var summary: String {
            String(
                format: "sensitive recall %d/%d (%.3f), likely %d/%d (%.3f), precision %d/%d (%.3f), "
                    + "ambiguous surfaced %d/%d (%.3f), benign hits %d",
                sensitiveFound, sensitive, recall, sensitiveLikely, sensitive, likelyRecall,
                relevantDetections, detections, precision, ambiguousSurfaced, ambiguous,
                ambiguousRate, benignHits.count
            ) + "\n  missed: \(missed)\n  benign hits: \(benignHits)\n  unexpected: \(unexpected)"
                + "\n  imprecise value spans: \(imprecise)"
        }
    }

    // MARK: - Ground-truth text

    func testGroundTruthTextMeetsPrecisionAndRecallTargets() throws {
        var tally = Tally()
        for fixture in try oneXFixtures() {
            let truth = fixture.groundTruth
            var boxForObservation: [OCRObservation.ID: String] = [:]
            let observations = try truth.textBoxes.map { box in
                let observation = OCRObservation(
                    text: box.text,
                    boundingBox: try box.rect.normalizedRect(),
                    boundingBoxOrigin: .topLeft,
                    confidence: try Confidence(1)
                )
                boxForObservation[observation.id] = box.id
                return observation
            }
            let detections = ContextualSecretDetector().detect(in: observations)

            func overlap(_ detection: SecretDetection, _ span: FixtureSpan) -> Double {
                var shared = 0
                var total = 0
                for segment in span.segments {
                    let truthRange = segment.utf16Offset..<(segment.utf16Offset + segment.utf16Length)
                    total += truthRange.count
                    for found in detection.spans where boxForObservation[found.observationID] == segment.textBoxID {
                        shared += found.utf16Range.clamped(to: truthRange).count
                    }
                }
                return total == 0 ? 0 : Double(shared) / Double(total)
            }

            tally.detections += detections.count
            for detection in detections {
                let hits = truth.spans.filter { overlap(detection, $0) > 0 }
                if hits.contains(where: { $0.expectation != .benign }) {
                    tally.relevantDetections += 1
                } else if let benign = hits.first {
                    tally.benignHits.append("\(truth.id)/\(benign.id)/\(detection.evidence.ruleID.rawValue)")
                } else {
                    tally.unexpected.append("\(truth.id)/\(detection.evidence.ruleID.rawValue)")
                }
            }
            for span in truth.spans {
                let matching = detections.filter { overlap($0, span) > 0 }
                switch span.expectation {
                case .sensitive:
                    tally.sensitive += 1
                    if matching.isEmpty {
                        tally.missed.append("\(truth.id)/\(span.id)")
                    } else {
                        tally.sensitiveFound += 1
                        if matching.contains(where: { $0.assessment == .likely }) { tally.sensitiveLikely += 1 }
                        // The finding covers the value, not its label: most of the value is
                        // covered and the finding does not spill far beyond it.
                        let best = matching.map { overlap($0, span) }.max() ?? 0
                        let spill = matching.flatMap(\.spans).map(\.utf16Range.count).reduce(0, +)
                        let valueLength = span.segments.map(\.utf16Length).reduce(0, +)
                        if best < Self.minimumValueOverlap || Double(spill) > Double(valueLength) * 1.25 {
                            tally.imprecise.append("\(truth.id)/\(span.id)")
                        }
                    }
                case .ambiguous:
                    tally.ambiguous += 1
                    if !matching.isEmpty { tally.ambiguousSurfaced += 1 }
                case .benign:
                    break
                }
            }
        }

        print("Detector on ground-truth text: \(tally.summary)")
        XCTAssertGreaterThanOrEqual(tally.recall, Self.groundTruthSensitiveRecall, tally.summary)
        XCTAssertGreaterThanOrEqual(tally.likelyRecall, Self.groundTruthLikelyRecall, tally.summary)
        XCTAssertGreaterThanOrEqual(tally.precision, Self.groundTruthPrecision, tally.summary)
        XCTAssertGreaterThanOrEqual(tally.ambiguousRate, Self.groundTruthAmbiguousSurfaced, tally.summary)
        XCTAssertLessThanOrEqual(tally.benignHits.count, Self.groundTruthMaximumBenignHits, tally.summary)
        XCTAssertEqual(tally.imprecise, [], "Findings must cover the value only")
    }

    // MARK: - Vision OCR end to end

    func testVisionOCRPipelineMeetsRecallAndPrecisionTargets() async throws {
        var tally = Tally()
        for fixture in try oneXFixtures() {
            let truth = fixture.groundTruth
            let imported = try await ImageIOImageImporter().importImage(from: fixture.imageURL)
            let dimensions = imported.pixelDimensions
            let observations = try await VisionTextRecognizer()
                .recognizeText(in: imported.pixels, dimensions: dimensions)
            let detections = try await ContextualSecretDetector().detectSecrets(in: observations)
            let byID = Dictionary(uniqueKeysWithValues: observations.map { ($0.id, $0) })

            /// A detection matches a span when one of its spans sits on the span's line and its
            /// text approximately equals one of the span's segments.
            func matches(_ detection: SecretDetection, _ span: FixtureSpan) throws -> Bool {
                for found in detection.spans {
                    guard let observation = byID[found.observationID] else { continue }
                    let box = try observation.imageRect(in: dimensions)
                        .normalized(in: dimensions, targetOrigin: .topLeft)
                    let utf16 = Array(observation.text.utf16)
                    let text = String(decoding: utf16[found.utf16Range], as: UTF16.self)
                    for segment in span.segments {
                        let target = try segment.rect.normalizedRect()
                        let vertical = min(box.y + box.height, target.y + target.height) - max(box.y, target.y)
                        guard vertical >= 0.5 * min(box.height, target.height),
                              let truthText = truth.text(of: segment) else { continue }
                        let error = min(
                            VisionTextRecognizerTests.approximateSubstringErrorRate(of: truthText, in: text),
                            VisionTextRecognizerTests.approximateSubstringErrorRate(of: text, in: truthText)
                        )
                        if error <= 0.25 { return true }
                    }
                }
                return false
            }

            tally.detections += detections.count
            for detection in detections {
                let relevant = try truth.spans.contains { span in
                    guard span.expectation != .benign else { return false }
                    return try matches(detection, span)
                }
                if relevant {
                    tally.relevantDetections += 1
                } else if let benign = try truth.spans.first(where: { try matches(detection, $0) }) {
                    tally.benignHits.append("\(truth.id)/\(benign.id)/\(detection.evidence.ruleID.rawValue)")
                } else {
                    tally.unexpected.append("\(truth.id)/\(detection.evidence.ruleID.rawValue)")
                }
            }
            for span in truth.spans where span.expectation != .benign {
                let matching = try detections.filter { try matches($0, span) }
                let found = !matching.isEmpty
                if span.expectation == .sensitive {
                    tally.sensitive += 1
                    if found { tally.sensitiveFound += 1 } else { tally.missed.append("\(truth.id)/\(span.id)") }
                    if matching.contains(where: { $0.assessment == .likely }) { tally.sensitiveLikely += 1 }
                } else {
                    tally.ambiguous += 1
                    if found { tally.ambiguousSurfaced += 1 }
                }
            }
        }

        print("Detector on Vision OCR: \(tally.summary)")
        XCTAssertGreaterThanOrEqual(tally.recall, Self.visionSensitiveRecall, tally.summary)
        XCTAssertGreaterThanOrEqual(tally.precision, Self.visionPrecision, tally.summary)
    }

    private func oneXFixtures() throws -> [LoadedFixture] {
        try FixtureLibrary.bundled().fixtures().filter { $0.groundTruth.scale == 1 }
    }
}
