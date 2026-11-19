import Foundation

/// A fresh, authenticated VS Code hint that matched a native finding: the same rule ID, and a
/// keyed digest equal to the digest RedScreen computed from the finding's OCR text. Carries no
/// digest, value, or document identifier.
public struct EditorHintConfirmation: Equatable, Hashable, Sendable {
    public let ruleID: DetectorRuleID
    /// The extension's confidence, 0–1.
    public let confidence: Confidence

    public init(ruleID: DetectorRuleID, confidence: Confidence) {
        self.ruleID = ruleID
        self.confidence = confidence
    }
}
