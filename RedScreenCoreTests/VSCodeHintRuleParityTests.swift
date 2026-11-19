import Foundation
import XCTest

@testable import RedScreenCore

/// RED-12: the VS Code extension and the native detector agree, by rule ID, on the shared
/// synthetic fixture in Extensions/vscode/test/fixtures/rule-parity.json. The extension's own
/// tests check the same file, so a hint's rule ID means the same thing on both sides.
final class VSCodeHintRuleParityTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Positive: Decodable {
            let id: String
            let lines: [[String]]
            let value: [String]
            let rule: String
        }
        struct Negative: Decodable {
            let id: String
            let lines: [[String]]
        }
        let positives: [Positive]
        let negatives: [Negative]
    }

    private let detector = ContextualSecretDetector()

    private func fixture() throws -> Fixture {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("Extensions/vscode/test/fixtures/rule-parity.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    func testNativeDetectorMatchesEveryParityPositiveByRuleID() throws {
        let fixture = try fixture()
        XCTAssertGreaterThanOrEqual(fixture.positives.count, 14)
        for testCase in fixture.positives {
            let input = observations(testCase.lines.map { $0.joined() })
            let value = testCase.value.joined()
            let detections = detector.detect(in: input)
            guard let detection = detections.first(where: { detection in
                detection.spans.map { text(of: $0, in: input) }.joined() == value
            }) else {
                XCTFail("\(testCase.id): no native finding covering exactly the value; rules "
                        + detections.map(\.evidence.ruleID.rawValue).joined(separator: ", "))
                continue
            }
            XCTAssertEqual(detection.evidence.ruleID.rawValue, testCase.rule, testCase.id)
        }
    }

    func testNativeDetectorFindsNothingInParityNegatives() throws {
        for testCase in try fixture().negatives {
            let detections = detector.detect(in: observations(testCase.lines.map { $0.joined() }))
            XCTAssertEqual(detections.map(\.evidence.ruleID.rawValue), [], testCase.id)
        }
    }

    /// Every rule ID the extension may send is one the native detector emits.
    func testExtensionRuleIDsAreNativeRuleIDs() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let extensionRules = try String(contentsOf: root.appendingPathComponent("Extensions/vscode/src/rules.ts"),
                                        encoding: .utf8)
        let native = try String(contentsOf: root.appendingPathComponent(
            "RedScreenCore/Services/Detection/ContextualSecretDetector.swift"), encoding: .utf8)
        let block = try XCTUnwrap(extensionRules.range(of: "export const RULE_IDS = [")
            .flatMap { start in extensionRules.range(of: "] as const", range: start.upperBound..<extensionRules.endIndex)
                .map { extensionRules[start.upperBound..<$0.lowerBound] } })
        let ids = block.split(separator: "'").enumerated().filter { $0.offset % 2 == 1 }.map { String($0.element) }
        XCTAssertGreaterThanOrEqual(ids.count, 19)
        for id in ids {
            XCTAssertTrue(native.contains("\"\(id)\""), "\(id) is not a native rule ID")
        }
    }

    private func text(of span: DetectedTextSpan, in observations: [OCRObservation]) -> String {
        let text = observations.first { $0.id == span.observationID }!.text
        return String(decoding: Array(text.utf16)[span.utf16Range], as: UTF16.self)
    }

    private func observations(_ lines: [String]) -> [OCRObservation] {
        lines.enumerated().map { index, line in
            OCRObservation(
                text: line,
                boundingBox: try! NormalizedRect(x: 0.05, y: min(0.02 + Double(index) * 0.05, 0.95), width: 0.9, height: 0.04),
                boundingBoxOrigin: .topLeft,
                confidence: try! Confidence(0.9)
            )
        }
    }
}
