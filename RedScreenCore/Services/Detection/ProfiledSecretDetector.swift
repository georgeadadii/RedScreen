import Foundation

/// What a profile changed in one detection pass, so exclusions are never invisible.
public struct DetectionProfileReport: Equatable, Sendable {
    public let profileName: String
    /// Findings hidden because their rule is turned off.
    public let hiddenByDisabledRules: Int
    /// Findings hidden because their value is a listed placeholder.
    public let hiddenByPlaceholders: Int
    /// Findings hidden because they fall below the profile's review threshold but would show
    /// with the default.
    public let hiddenByThreshold: Int
    /// Findings added by custom rules.
    public let customFindings: Int

    public var hiddenTotal: Int { hiddenByDisabledRules + hiddenByPlaceholders + hiddenByThreshold }
}

/// A detector that reports what its configuration hid or added.
public protocol ReportingSecretDetector: SecretDetector {
    func detectSecretsWithReport(in observations: [OCRObservation]) async throws -> ([SecretDetection], DetectionProfileReport)
}

/// The native detector configured by a `DetectionProfile`.
///
/// - Balanced reproduces `ContextualSecretDetector()` exactly.
/// - Thresholds, disabled rules, and placeholders can only hide findings; each hidden finding is
///   counted in the report, which the review UI shows.
/// - Custom rules add findings through `CustomRuleMatcher`, a linear scanner with no regular
///   expressions. A native finding always wins where they overlap, keeping native provenance.
public struct ProfiledSecretDetector: ReportingSecretDetector {
    public let profile: DetectionProfile

    public init(profile: DetectionProfile) {
        self.profile = profile
    }

    public func detectSecrets(in observations: [OCRObservation]) async throws -> [SecretDetection] {
        try await detectSecretsWithReport(in: observations).0
    }

    public func detectSecretsWithReport(in observations: [OCRObservation]) async throws -> ([SecretDetection], DetectionProfileReport) {
        try Task.checkCancellation()
        let result = detect(in: observations)
        try Task.checkCancellation()
        return result
    }

    /// Synchronous, deterministic entry point.
    public func detect(in observations: [OCRObservation]) -> ([SecretDetection], DetectionProfileReport) {
        // Detect at the lower of the profile's and the default review thresholds, so findings the
        // profile hides by threshold can be counted rather than silently dropped.
        var thresholds = profile.thresholds
        let defaultReview = SecretDetectionThresholds.standard.reviewConfidence
        thresholds.reviewConfidence = min(thresholds.reviewConfidence, defaultReview)
        let native = ContextualSecretDetector(thresholds: thresholds).detect(in: observations)
        let byID = Dictionary(uniqueKeysWithValues: observations.map { ($0.id, $0) })
        let placeholders = Set(profile.placeholders.map { HintProtocol.normalize($0).lowercased() })
        let review = Double(profile.reviewThreshold) / 100

        var kept: [SecretDetection] = []
        var hiddenByRule = 0, hiddenByPlaceholder = 0, hiddenByThreshold = 0
        for detection in native {
            let rule = BuiltInDetectionRule.base(of: detection.evidence.ruleID.rawValue)
            if profile.disabledRules.contains(rule) {
                hiddenByRule += 1
            } else if !placeholders.isEmpty, let value = EditorHintStore.value(of: detection, in: byID),
                      placeholders.contains(HintProtocol.normalize(value).lowercased()) {
                hiddenByPlaceholder += 1
            } else if detection.evidence.confidence.value < review {
                hiddenByThreshold += 1
            } else {
                kept.append(detection)
            }
        }

        let custom = CustomRuleMatcher(rules: profile.customRules, thresholds: profile.thresholds)
            .detect(in: observations, excludingPlaceholders: placeholders)
            .filter { candidate in !kept.contains { overlaps($0, candidate) } }
        // Native order is kept exactly; custom findings are merged in reading order.
        let combined = custom.isEmpty ? kept
            : (kept + custom).sorted { position($0, byID).lexicographicallyPrecedes(position($1, byID)) }
        let report = DetectionProfileReport(
            profileName: profile.name, hiddenByDisabledRules: hiddenByRule, hiddenByPlaceholders: hiddenByPlaceholder,
            hiddenByThreshold: hiddenByThreshold, customFindings: custom.count
        )
        return (combined, report)
    }

    private func overlaps(_ a: SecretDetection, _ b: SecretDetection) -> Bool {
        a.spans.contains { left in
            b.spans.contains { $0.observationID == left.observationID && $0.utf16Range.overlaps(left.utf16Range) }
        }
    }

    /// Reading order: line position, then column.
    private func position(_ detection: SecretDetection, _ observations: [OCRObservation.ID: OCRObservation]) -> [Double] {
        guard let span = detection.spans.first, let observation = observations[span.observationID] else { return [.infinity] }
        let box = observation.boundingBox
        return [box.y, box.x, Double(span.utf16Range.lowerBound)]
    }
}

/// Matches custom rules in time linear in the text length (times the bounded prefix and key
/// lengths). Each observation is scanned at most `maximumAnalyzedUTF16PerObservation` units.
public struct CustomRuleMatcher: Sendable {
    public let rules: [CustomDetectionRule]
    public let thresholds: SecretDetectionThresholds

    public init(rules: [CustomDetectionRule], thresholds: SecretDetectionThresholds) {
        self.rules = rules
        self.thresholds = thresholds
    }

    public func detect(in observations: [OCRObservation], excludingPlaceholders placeholders: Set<String> = []) -> [SecretDetection] {
        guard !rules.isEmpty else { return [] }
        var detections: [SecretDetection] = []
        for observation in observations.prefix(thresholds.maximumObservations) {
            let scalars = Array(observation.text.unicodeScalars.prefix(thresholds.maximumAnalyzedUTF16PerObservation))
            var claimed: [Range<Int>] = []
            for rule in rules {
                for range in matches(of: rule, in: scalars) where !claimed.contains(where: { $0.overlaps(range) }) {
                    let value = String(String.UnicodeScalarView(scalars[range]))
                    if placeholders.contains(HintProtocol.normalize(value).lowercased()) { continue }
                    guard let detection = makeDetection(rule, range: range, scalars: scalars, observation: observation) else { continue }
                    claimed.append(range)
                    detections.append(detection)
                }
            }
        }
        return detections
    }

    /// Scalar ranges of the values `rule` matches in `scalars`.
    func matches(of rule: CustomDetectionRule, in scalars: [Unicode.Scalar]) -> [Range<Int>] {
        switch rule.kind {
        case .token: tokenMatches(rule, scalars)
        case .keyValue: keyValueMatches(rule, scalars)
        }
    }

    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        CustomDetectionRule.CharacterClass.alphanumericDashUnderscore.contains(scalar)
    }

    private func tokenMatches(_ rule: CustomDetectionRule, _ scalars: [Unicode.Scalar]) -> [Range<Int>] {
        let prefix = Array(rule.prefix.unicodeScalars)
        guard !prefix.isEmpty, scalars.count >= prefix.count else { return [] }
        var results: [Range<Int>] = []
        var index = 0
        while index + prefix.count <= scalars.count {
            guard scalars[index..<(index + prefix.count)].elementsEqual(prefix),
                  index == 0 || !Self.isWordScalar(scalars[index - 1]) else {
                index += 1
                continue
            }
            var end = index + prefix.count
            let bodyStart = end
            while end < scalars.count, end - bodyStart <= rule.maximumLength, rule.characters.contains(scalars[end]) { end += 1 }
            let length = end - bodyStart
            // Too long means a different, longer token: not this rule's shape.
            if length >= rule.minimumLength, length <= rule.maximumLength {
                results.append(index..<end)
            }
            index = max(end, index + 1)
        }
        return results
    }

    private func keyValueMatches(_ rule: CustomDetectionRule, _ scalars: [Unicode.Scalar]) -> [Range<Int>] {
        // Keys are ASCII (validated), so ASCII case folding is exact.
        let lowered = scalars.map { (0x41...0x5A).contains($0.value) ? Unicode.Scalar($0.value + 32)! : $0 }
        var results: [Range<Int>] = []
        for key in rule.keys {
            let pattern = Array(key.lowercased().unicodeScalars)
            var index = 0
            while index + pattern.count <= lowered.count {
                guard lowered[index..<(index + pattern.count)].elementsEqual(pattern),
                      index == 0 || !Self.isWordScalar(scalars[index - 1]),
                      index + pattern.count == scalars.count || !Self.isWordScalar(scalars[index + pattern.count]) else {
                    index += 1
                    continue
                }
                var cursor = index + pattern.count
                func skip(_ allowed: Set<Unicode.Scalar>) { while cursor < scalars.count, allowed.contains(scalars[cursor]) { cursor += 1 } }
                skip(["\"", "'", " ", "\t"])
                guard cursor < scalars.count, scalars[cursor] == "=" || scalars[cursor] == ":" else {
                    index += 1
                    continue
                }
                cursor += 1
                skip([" ", "\t", "\"", "'", "`"])
                let start = cursor
                while cursor < scalars.count, cursor - start <= rule.maximumLength,
                      !" \t\"'`,;".unicodeScalars.contains(scalars[cursor]) { cursor += 1 }
                let length = cursor - start
                if length >= rule.minimumLength, length <= rule.maximumLength { results.append(start..<cursor) }
                index = max(cursor, index + 1)
            }
        }
        return results.sorted { $0.lowerBound < $1.lowerBound }
    }

    private func makeDetection(
        _ rule: CustomDetectionRule, range: Range<Int>, scalars: [Unicode.Scalar], observation: OCRObservation
    ) -> SecretDetection? {
        // Spans are UTF-16 offsets, like the native detector's.
        let utf16Start = scalars[..<range.lowerBound].reduce(0) { $0 + UTF16.width($1) }
        let utf16Length = scalars[range].reduce(0) { $0 + UTF16.width($1) }
        let confidenceValue = Double(rule.confidence) / 100
        guard let assessment = thresholds.assessment(for: confidenceValue),
              let ruleID = try? DetectorRuleID(rule.id),
              let confidence = try? Confidence(confidenceValue),
              let evidence = try? DetectionEvidence(ruleID: ruleID, observationIDs: [observation.id], confidence: confidence) else {
            return nil
        }
        let family: SecretFamily = rule.kind == .token ? .providerKeyShape : .credentialKeyword
        return try? SecretDetection(
            evidence: evidence, family: family, severity: family.severity, assessment: assessment,
            spans: [DetectedTextSpan(observationID: observation.id, utf16Range: utf16Start..<(utf16Start + utf16Length))]
        )
    }
}
