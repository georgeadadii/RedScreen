import Foundation

/// Classifies likely developer secrets in OCR observations using key, label, and neighbouring
/// context (issue #7).
///
/// The detector is pure Swift: it consumes `OCRObservation`s only, never image data, and is
/// independent of Vision and SwiftUI. It is deterministic for a given input apart from fresh
/// detection IDs. Work is bounded by `SecretDetectionThresholds`: a fixed number of observations
/// and characters per observation are analysed, every pattern uses bounded quantifiers, and
/// private key blocks are capped in length.
///
/// Findings locate the **value** only (never its label) as UTF-16 ranges in the original
/// observation text, and copy no matched text. Findings below the review threshold are dropped;
/// those between the review and likely thresholds are returned as `needsReview`.
public struct ContextualSecretDetector: SecretDetector {
    public let thresholds: SecretDetectionThresholds

    public init(thresholds: SecretDetectionThresholds = .standard) {
        self.thresholds = thresholds
    }

    public func detectSecrets(in observations: [OCRObservation]) async throws -> [SecretDetection] {
        try detect(in: observations, checkCancellation: { try Task.checkCancellation() })
    }

    /// Synchronous entry point used by tests and evaluation.
    public func detect(in observations: [OCRObservation]) -> [SecretDetection] {
        (try? detect(in: observations, checkCancellation: {})) ?? []
    }

    private func detect(
        in observations: [OCRObservation],
        checkCancellation: () throws -> Void
    ) throws -> [SecretDetection] {
        let lines = observations.prefix(thresholds.maximumObservations).enumerated().map {
            Line(index: $0.offset, observation: $0.element, thresholds: thresholds)
        }
        let readingOrder = lines.sorted {
            if abs($0.top - $1.top) > min($0.height, $1.height) * 0.5 { return $0.top < $1.top }
            return $0.left < $1.left
        }

        var findings: [Finding] = []
        let privateKeys = privateKeyFindings(readingOrder)
        findings += privateKeys.findings
        let remaining = readingOrder.filter { !privateKeys.consumedLines.contains($0.index) }

        for (offset, line) in remaining.enumerated() {
            if offset % 256 == 0 { try checkCancellation() }
            findings += connectionStringFindings(line)
            findings += bearerFindings(line)
            findings += providerFindings(line)
            findings += assignmentFindings(line)
            findings += proseQuotedFindings(line)
            findings += highEntropyFindings(line)
        }
        findings += wrappedConnectionStringFindings(remaining)
        findings += tableLabelFindings(remaining)
        try checkCancellation()

        return resolve(findings, lineOrder: Dictionary(
            uniqueKeysWithValues: readingOrder.enumerated().map { ($0.element.observation.id, $0.offset) }
        ))
    }

    // MARK: - Lines

    struct Line {
        let index: Int
        let observation: OCRObservation
        let normalized: NormalizedLine
        /// Top-left normalized geometry for neighbour reasoning.
        let left: Double
        let top: Double
        let width: Double
        let height: Double

        init(index: Int, observation: OCRObservation, thresholds: SecretDetectionThresholds) {
            self.index = index
            self.observation = observation
            normalized = NormalizedLine(
                observation.text, maximumUTF16: thresholds.maximumAnalyzedUTF16PerObservation
            )
            let box = observation.boundingBox
            left = box.x
            width = box.width
            height = box.height
            top = observation.boundingBoxOrigin == .topLeft ? box.y : 1 - box.y - box.height
        }

        var right: Double { left + width }
        var bottom: Double { top + height }
        var id: OCRObservation.ID { observation.id }

        func span(_ range: NSRange) -> DetectedTextSpan {
            DetectedTextSpan(observationID: id, utf16Range: range.location..<NSMaxRange(range))
        }

        /// Range of the text with surrounding whitespace removed.
        var trimmedRange: NSRange? {
            let text = normalized.nsText
            let nonSpace = CharacterSet.whitespacesAndNewlines.inverted
            let start = text.rangeOfCharacter(from: nonSpace)
            let end = text.rangeOfCharacter(from: nonSpace, options: .backwards)
            guard start.location != NSNotFound, end.location != NSNotFound else { return nil }
            return NSRange(location: start.location, length: NSMaxRange(end) - start.location)
        }
    }

    struct Finding {
        let ruleID: String
        let family: SecretFamily
        let confidence: Double
        let spans: [DetectedTextSpan]
    }

    // MARK: - Private keys

    nonisolated(unsafe) private static let privateKeyBegin = regex(#"-{2,}\s{0,3}BEGIN\s{1,3}([A-Z0-9 ]{0,40}?)\s{0,3}-{2,}"#)
    nonisolated(unsafe) private static let privateKeyEnd = regex(#"-{2,}\s{0,3}END\s{1,3}[A-Z0-9 ]{0,40}"#)

    private func privateKeyFindings(_ lines: [Line]) -> (findings: [Finding], consumedLines: Set<Int>) {
        var findings: [Finding] = []
        var consumed: Set<Int> = []
        var position = 0
        while position < lines.count {
            let header = lines[position]
            guard let match = Self.firstMatch(Self.privateKeyBegin, in: header.normalized),
                  header.normalized.substring(match.range(at: 1)).contains("PRIVATE KEY") else {
                position += 1
                continue
            }
            let kind = header.normalized.substring(match.range(at: 1))
            var block = [header]
            var ended = false
            var next = position + 1
            while next < lines.count, block.count < thresholds.maximumPrivateKeyLines {
                let line = lines[next]
                guard abs(line.left - header.left) <= 0.1 else { next += 1; continue }
                block.append(line)
                next += 1
                if Self.firstMatch(Self.privateKeyEnd, in: line.normalized) != nil {
                    ended = true
                    break
                }
            }
            let encrypted = kind.contains("ENCRYPTED")
                || block.dropFirst().prefix(2).contains { $0.normalized.text.contains("ENCRYPTED") }
            let confidence = encrypted ? 0.55 : (ended ? 0.97 : 0.9)
            let spans = block.compactMap { line in line.trimmedRange.map(line.span) }
            findings.append(Finding(
                ruleID: encrypted ? "private-key.encrypted-block" : "private-key.block",
                family: .privateKey,
                confidence: confidence,
                spans: spans
            ))
            block.forEach { consumed.insert($0.index) }
            position = next
        }
        return (findings, consumed)
    }

    // MARK: - Connection strings

    nonisolated(unsafe) private static let connectionURL = regex(
        #"(?<![A-Za-z0-9])([a-zA-Z][a-zA-Z0-9+.\-]{1,20})://([^\s:/@'"`]{0,128})(?::([^\s@/'"`]{0,256}))?@([A-Za-z0-9.\-\[\]]{1,253})"#
    )
    nonisolated(unsafe) private static let unfinishedCredentialURL = regex(
        #"(?<![A-Za-z0-9])[a-zA-Z][a-zA-Z0-9+.\-]{1,20}://[^\s:/@'"`]{0,128}:[^\s@/'"`]{0,256}$"#
    )
    private static let usernameOnlyExclusions: Set<String> = ["git", "anonymous", "ftp"]

    private func connectionStringFindings(_ line: Line) -> [Finding] {
        connectionMatches(in: line.normalized).compactMap { match in
            classifyConnection(match, text: line.normalized) { range in [line.span(range)] }
        }
    }

    /// Joins a line that ends inside a URL's password with the line directly below it.
    private func wrappedConnectionStringFindings(_ lines: [Line]) -> [Finding] {
        var findings: [Finding] = []
        for line in lines {
            let text = line.normalized.text.trimmingCharacters(in: .whitespaces)
            let probe = NormalizedLine(text, maximumUTF16: text.utf16.count)
            guard Self.firstMatch(Self.unfinishedCredentialURL, in: probe) != nil,
                  let continuation = lineBelow(line, in: lines) else {
                continue
            }
            let firstLength = line.normalized.length
            let joined = NormalizedLine(
                line.normalized.text + continuation.normalized.text,
                maximumUTF16: firstLength + continuation.normalized.length
            )
            for match in connectionMatches(in: joined) where match.range.location < firstLength
                && NSMaxRange(match.range) > firstLength {
                if let finding = classifyConnection(match, text: joined, spans: { range in
                    split(range, at: firstLength, first: line, second: continuation)
                }) {
                    findings.append(Finding(
                        ruleID: finding.ruleID + ".wrapped",
                        family: finding.family,
                        confidence: finding.confidence,
                        spans: finding.spans
                    ))
                }
            }
        }
        return findings
    }

    private func connectionMatches(in text: NormalizedLine) -> [NSTextCheckingResult] {
        Self.connectionURL.matches(in: text.text, range: NSRange(location: 0, length: text.length))
    }

    private func classifyConnection(
        _ match: NSTextCheckingResult,
        text: NormalizedLine,
        spans: (NSRange) -> [DetectedTextSpan]
    ) -> Finding? {
        let userRange = match.range(at: 2)
        let passwordRange = match.range(at: 3)
        if passwordRange.location != NSNotFound, passwordRange.length > 0 {
            let password = text.substring(passwordRange)
            guard ValueAnalysis.kind(of: password) != .notSecret else { return nil }
            return Finding(
                ruleID: "connection-string.password",
                family: .connectionString,
                confidence: 0.95,
                spans: spans(passwordRange)
            )
        }
        let user = text.substring(userRange)
        guard !user.isEmpty, !Self.usernameOnlyExclusions.contains(user.lowercased()),
              !ValueAnalysis.isPlaceholderShape(user) else {
            return nil
        }
        return Finding(
            ruleID: "connection-string.username-only",
            family: .connectionString,
            confidence: 0.45,
            spans: spans(userRange)
        )
    }

    private func split(_ range: NSRange, at boundary: Int, first: Line, second: Line)
        -> [DetectedTextSpan] {
        var spans: [DetectedTextSpan] = []
        if range.location < boundary {
            let end = min(NSMaxRange(range), boundary)
            if end > range.location {
                spans.append(first.span(NSRange(location: range.location, length: end - range.location)))
            }
        }
        if NSMaxRange(range) > boundary {
            let start = max(range.location, boundary) - boundary
            let end = NSMaxRange(range) - boundary
            spans.append(second.span(NSRange(location: start, length: end - start)))
        }
        return spans
    }

    /// The nearest line directly below `line` that starts at roughly the same left edge.
    private func lineBelow(_ line: Line, in lines: [Line]) -> Line? {
        lines.filter { candidate in
            candidate.index != line.index
                && candidate.top > line.top + line.height * 0.5
                && candidate.top - line.bottom <= line.height * 1.5
                && abs(candidate.left - line.left) <= 0.05
        }
        .min { $0.top < $1.top }
    }

    // MARK: - Bearer tokens

    nonisolated(unsafe) private static let bearer = regex(#"(?i)\bbearer\s{1,4}([A-Za-z0-9._~+/=\-]{1,512})"#)

    private func bearerFindings(_ line: Line) -> [Finding] {
        let text = line.normalized
        return Self.bearer.matches(in: text.text, range: NSRange(location: 0, length: text.length))
            .compactMap { match in
                let range = match.range(at: 1)
                let token = text.substring(range)
                guard token.count >= 8,
                      !ValueAnalysis.placeholderWords.contains(token.lowercased()),
                      ValueAnalysis.kind(of: token) != .notSecret else {
                    return nil
                }
                let after = NSMaxRange(range) < text.length
                    ? text.substring(NSRange(location: NSMaxRange(range), length: 1)) : ""
                let truncated = token.hasSuffix("...") || after == "\u{2026}"
                let confidence: Double
                if truncated {
                    confidence = 0.5
                } else if token.hasPrefix("eyJ") || token.contains(".eyJ") || token.count >= 16 {
                    confidence = 0.95
                } else {
                    confidence = 0.55
                }
                return Finding(
                    ruleID: truncated ? "bearer.truncated" : "bearer.token",
                    family: .bearerToken,
                    confidence: confidence,
                    spans: [line.span(range)]
                )
            }
    }

    // MARK: - Provider key shapes

    private struct ProviderPattern {
        let ruleID: String
        let expression: NSRegularExpression
        let confidence: Double
    }

    /// `@` is accepted where a `0` is expected because OCR confuses them.
    nonisolated(unsafe) private static let providerPatterns: [ProviderPattern] = [
        ProviderPattern(ruleID: "provider.github-token",
            expression: regex(#"(?<![A-Za-z0-9_])gh[pousr]_[A-Za-z0-9@]{36}(?![A-Za-z0-9])"#), confidence: 0.97),
        ProviderPattern(ruleID: "provider.github-fine-grained-token",
            expression: regex(#"(?<![A-Za-z0-9_])github_pat_[A-Za-z0-9_]{22,255}"#), confidence: 0.97),
        ProviderPattern(ruleID: "provider.gitlab-token",
            expression: regex(#"(?<![A-Za-z0-9_])glpat-[A-Za-z0-9_\-]{20,64}"#), confidence: 0.95),
        ProviderPattern(ruleID: "provider.slack-token",
            expression: regex(#"(?<![A-Za-z0-9_])xox[abprs]-[A-Za-z0-9\-]{10,128}"#), confidence: 0.95),
        ProviderPattern(ruleID: "provider.stripe-live-key",
            expression: regex(#"(?<![A-Za-z0-9_])(?:sk|rk)_live_[A-Za-z0-9]{16,128}"#), confidence: 0.97),
        ProviderPattern(ruleID: "provider.stripe-test-key",
            expression: regex(#"(?<![A-Za-z0-9_])(?:sk|rk)_test_[A-Za-z0-9]{16,128}"#), confidence: 0.75),
        ProviderPattern(ruleID: "provider.google-api-key",
            expression: regex(#"(?<![A-Za-z0-9_])AIza[0-9A-Za-z_\-]{35}"#), confidence: 0.9),
        ProviderPattern(ruleID: "provider.npm-token",
            expression: regex(#"(?<![A-Za-z0-9_])npm_[A-Za-z0-9]{36}"#), confidence: 0.95),
        ProviderPattern(ruleID: "provider.anthropic-key",
            expression: regex(#"(?<![A-Za-z0-9_])sk-ant-[A-Za-z0-9_\-]{20,256}"#), confidence: 0.97),
        ProviderPattern(ruleID: "provider.openai-key",
            expression: regex(#"(?<![A-Za-z0-9_])sk-(?:proj-)?[A-Za-z0-9_\-]{32,256}"#), confidence: 0.85),
        ProviderPattern(ruleID: "provider.jwt",
            expression: regex(#"eyJ[A-Za-z0-9_\-]{8,2048}\.eyJ[A-Za-z0-9_\-]{8,2048}\.[A-Za-z0-9_\-]{8,2048}"#),
            confidence: 0.85),
    ]
    nonisolated(unsafe) private static let awsAccessKeyID = regex(#"(?<![A-Z0-9])(?:AKIA|ASIA)[A-Z0-9]{16}(?![A-Z0-9])"#)
    nonisolated(unsafe) private static let exportedAccessKey = regex(#"(?i)(?:export\s+)?[A-Z_]*ACCESS_KEY_ID\s*="#)

    private func providerFindings(_ line: Line) -> [Finding] {
        let text = line.normalized
        let all = NSRange(location: 0, length: text.length)
        var findings: [Finding] = []
        for pattern in Self.providerPatterns {
            for match in pattern.expression.matches(in: text.text, range: all) {
                findings.append(Finding(
                    ruleID: pattern.ruleID,
                    family: .providerKeyShape,
                    confidence: pattern.confidence,
                    spans: [line.span(match.range)]
                ))
            }
        }
        // An access key ID alone is an identifier; exported beside its secret it is a credential.
        let exported = Self.firstMatch(Self.exportedAccessKey, in: text) != nil
        for match in Self.awsAccessKeyID.matches(in: text.text, range: all) {
            findings.append(Finding(
                ruleID: "provider.aws-access-key-id",
                family: .providerKeyShape,
                confidence: exported ? 0.9 : 0.6,
                spans: [line.span(match.range)]
            ))
        }
        return findings
    }

    // MARK: - Key/value assignments (env, JSON, YAML, code, prose)

    nonisolated(unsafe) private static let separator = regex(#"(?:=(?!=)|:(?!//)|\b(?:is|was)\b)"#)
    nonisolated(unsafe) private static let envLine = regex(#"^\s{0,8}(?:export\s{1,4})?[A-Z][A-Z0-9_]{0,63}\s{0,3}="#)

    private func assignmentFindings(_ line: Line) -> [Finding] {
        let text = line.normalized
        let isEnvLine = Self.firstMatch(Self.envLine, in: text) != nil
        var findings: [Finding] = []
        for match in Self.separator.matches(in: text.text, range: NSRange(location: 0, length: text.length)) {
            guard let key = keyPhrase(before: match.range.location, in: text) else { continue }
            let classification = SecretKeywords.classify(key)
            guard classification.strength != .none,
                  let valueRange = valueRange(after: NSMaxRange(match.range), in: text) else {
                continue
            }
            let value = text.substring(valueRange)
            guard let scored = score(value: value, key: classification) else { continue }
            let family: SecretFamily
            let ruleID: String
            if classification.strength == .weak {
                (family, ruleID) = (.highEntropyContextual, "assignment.weak-context")
            } else if isEnvLine {
                (family, ruleID) = (.envAssignment, "assignment.env")
            } else {
                (family, ruleID) = (.credentialKeyword, "assignment.credential")
            }
            findings.append(Finding(
                ruleID: ruleID, family: family, confidence: scored, spans: [line.span(valueRange)]
            ))
        }
        return findings
    }

    /// Up to three words immediately before a separator, ignoring connectors such as `is`.
    private func keyPhrase(before location: Int, in text: NormalizedLine) -> String? {
        let prefix = text.substring(NSRange(location: 0, length: location))
        var words: [String] = []
        var current = ""
        func flush() {
            if !current.isEmpty { words.insert(current, at: 0) }
            current = ""
        }
        for character in prefix.reversed() {
            if character.isLetter || character.isNumber || "_-.".contains(character) {
                current.insert(character, at: current.startIndex)
            } else if character == " " || character == "\"" || character == "'" {
                flush()
                if words.count >= 4 { break }
            } else {
                flush()
                break
            }
        }
        flush()
        while let last = words.last, SecretKeywords.connectorWords.contains(last.lowercased()) {
            words.removeLast()
        }
        let phrase = words.suffix(3).joined(separator: " ")
        return phrase.isEmpty ? nil : phrase
    }

    /// The value after a separator: a quoted string, or a run up to whitespace or delimiters.
    private func valueRange(after location: Int, in text: NormalizedLine) -> NSRange? {
        let characters = text.nsText
        var start = location
        while start < text.length, characters.character(at: start) == 0x20 { start += 1 }
        guard start < text.length else { return nil }
        let first = characters.character(at: start)
        let quotes: Set<UInt16> = [0x22, 0x27, 0x60]
        var end: Int
        if quotes.contains(first) {
            start += 1
            end = start
            while end < text.length, characters.character(at: end) != first { end += 1 }
        } else {
            end = start
            let stops: Set<UInt16> = [0x20, 0x09, 0x2C, 0x3B, 0x7D, 0x29, 0x5D, 0x22, 0x27]
            while end < text.length, !stops.contains(characters.character(at: end)) { end += 1 }
            // Trailing sentence punctuation is not part of the value.
            while end > start, [0x2E, 0x3A, 0x21, 0x3F].contains(characters.character(at: end - 1)) {
                end -= 1
            }
        }
        guard end > start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    /// Confidence for a value under a key, or nil if it is not a finding.
    private func score(value: String, key: KeyClassification) -> Double? {
        let kind = ValueAnalysis.kind(of: value)
        var strength: Double
        switch kind {
        case .notSecret:
            return nil
        case .reviewOnly:
            strength = 0.6
        case .plainWord:
            strength = 0.3
        case .candidate:
            strength = ValueAnalysis.strength(of: value, thresholds: thresholds)
        }
        // Weak context words (`salt`, `nonce`, `id`) only flag random-looking values.
        if key.strength == .weak, !ValueAnalysis.isHighEntropy(value, thresholds: thresholds),
           !(value.count >= 10 && ValueAnalysis.entropy(value) >= thresholds.highEntropyBitsPerCharacter
               && value.contains(where: \.isNumber) && value.contains(where: \.isLetter)) {
            return nil
        }
        let weight = switch key.strength {
        case .strong: thresholds.strongKeywordWeight
        case .medium: thresholds.mediumKeywordWeight
        case .weak: thresholds.weakKeywordWeight
        case .none: 0.0
        }
        // Capped below specific shapes (provider tokens, bearer, URLs) so they win overlaps.
        var confidence = min(0.95, weight * strength)
        if kind == .reviewOnly || key.isHint {
            confidence = min(confidence, thresholds.likelyConfidence - 0.1)
        }
        guard confidence >= thresholds.reviewConfidence else { return nil }
        return confidence
    }

    // MARK: - Two-column tables

    /// A single-token value with a credential label immediately to its left on the same row.
    private func tableLabelFindings(_ lines: [Line]) -> [Finding] {
        var findings: [Finding] = []
        for value in lines {
            guard let range = value.trimmedRange else { continue }
            let token = value.normalized.substring(range)
            guard !token.contains(" "), !token.contains("=") else { continue }
            let label = lines.filter { candidate in
                guard candidate.index != value.index, candidate.right <= value.left + 0.01 else {
                    return false
                }
                let overlap = min(candidate.bottom, value.bottom) - max(candidate.top, value.top)
                return overlap >= 0.5 * min(candidate.height, value.height)
            }
            .max { $0.right < $1.right }
            guard let label else { continue }
            let labelText = label.normalized.text.trimmingCharacters(in: .whitespaces)
            guard !labelText.contains("="), labelText.split(separator: " ").count <= 5 else {
                continue
            }
            let classification = SecretKeywords.classify(
                labelText.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            )
            guard classification.strength != .none,
                  let confidence = score(value: token, key: classification) else {
                continue
            }
            findings.append(Finding(
                ruleID: "label.table",
                family: classification.strength == .weak ? .highEntropyContextual : .credentialKeyword,
                confidence: confidence,
                spans: [value.span(range)]
            ))
        }
        return findings
    }

    // MARK: - Prose

    nonisolated(unsafe) private static let quoted = regex(#"(['"`])([^'"`\s]{6,256})\1"#)

    /// A quoted, secret-looking token in a sentence about passwords or logging in.
    private func proseQuotedFindings(_ line: Line) -> [Finding] {
        let text = line.normalized
        let lower = text.text.lowercased()
        guard SecretKeywords.proseContextWords.contains(where: lower.contains) else { return [] }
        return Self.quoted.matches(in: text.text, range: NSRange(location: 0, length: text.length))
            .compactMap { match in
                let range = match.range(at: 2)
                let value = text.substring(range)
                guard ValueAnalysis.kind(of: value) == .candidate,
                      ValueAnalysis.strength(of: value, thresholds: thresholds) >= 0.8 else {
                    return nil
                }
                return Finding(
                    ruleID: "prose.quoted-credential",
                    family: .credentialKeyword,
                    confidence: 0.5,
                    spans: [line.span(range)]
                )
            }
    }

    // MARK: - High entropy in context

    nonisolated(unsafe) private static let token = regex(#"[A-Za-z0-9+/_\-]{16,512}={0,2}"#)

    /// Random-looking tokens preceded on the same line by a credential word, without a separator.
    private func highEntropyFindings(_ line: Line) -> [Finding] {
        let text = line.normalized
        return Self.token.matches(in: text.text, range: NSRange(location: 0, length: text.length))
            .compactMap { match in
                let value = text.substring(match.range)
                // AWS access key IDs are identifiers; the provider rule scores them.
                guard ValueAnalysis.isHighEntropy(value, thresholds: thresholds),
                      !ValueAnalysis.isHexOnly(value),
                      Self.firstMatch(Self.awsAccessKeyID, in: NormalizedLine(value, maximumUTF16: 64)) == nil
                else {
                    return nil
                }
                let start = max(0, match.range.location - 40)
                let context = text.substring(NSRange(location: start, length: match.range.location - start))
                let words = SecretKeywords.components(of: context)
                let classification = SecretKeywords.classify(words.suffix(3).joined(separator: " "))
                var confidence: Double
                switch classification.strength {
                case .none: return nil
                case .weak: confidence = 0.45
                case .medium: confidence = 0.6
                case .strong: confidence = 0.75
                }
                if classification.isHint { confidence = min(confidence, 0.45) }
                return Finding(
                    ruleID: "high-entropy.contextual",
                    family: .highEntropyContextual,
                    confidence: confidence,
                    spans: [line.span(match.range)]
                )
            }
    }

    // MARK: - Resolution

    /// Keeps the most confident finding where findings overlap, then orders by reading order.
    private func resolve(
        _ findings: [Finding],
        lineOrder: [OCRObservation.ID: Int]
    ) -> [SecretDetection] {
        let ranked = findings.filter { thresholds.assessment(for: $0.confidence) != nil }.sorted {
            if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
            if $0.spans.count != $1.spans.count { return $0.spans.count > $1.spans.count }
            return position($0, lineOrder) < position($1, lineOrder)
        }
        var accepted: [Finding] = []
        for finding in ranked where !accepted.contains(where: { overlaps($0, finding) }) {
            accepted.append(finding)
        }
        accepted.sort { position($0, lineOrder) < position($1, lineOrder) }

        return accepted.compactMap { finding in
            guard let assessment = thresholds.assessment(for: finding.confidence),
                  let ruleID = try? DetectorRuleID(finding.ruleID),
                  let confidence = try? Confidence(min(1, finding.confidence)) else {
                return nil
            }
            var observationIDs: [OCRObservation.ID] = []
            for span in finding.spans where !observationIDs.contains(span.observationID) {
                observationIDs.append(span.observationID)
            }
            guard let evidence = try? DetectionEvidence(
                ruleID: ruleID, observationIDs: observationIDs, confidence: confidence
            ) else {
                return nil
            }
            return try? SecretDetection(
                evidence: evidence,
                family: finding.family,
                severity: finding.family.severity,
                assessment: assessment,
                spans: finding.spans
            )
        }
    }

    private func overlaps(_ a: Finding, _ b: Finding) -> Bool {
        a.spans.contains { left in
            b.spans.contains { right in
                left.observationID == right.observationID && left.utf16Range.overlaps(right.utf16Range)
            }
        }
    }

    private func position(_ finding: Finding, _ order: [OCRObservation.ID: Int]) -> (Int, Int) {
        let first = finding.spans.min {
            (order[$0.observationID] ?? .max, $0.utf16Range.lowerBound)
                < (order[$1.observationID] ?? .max, $1.utf16Range.lowerBound)
        }
        return (first.flatMap { order[$0.observationID] } ?? .max, first?.utf16Range.lowerBound ?? 0)
    }

    // MARK: - Regex helpers

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Patterns are compile-time constants; a failure is a programming error.
        try! NSRegularExpression(pattern: pattern)
    }

    private static func firstMatch(_ expression: NSRegularExpression, in text: NormalizedLine)
        -> NSTextCheckingResult? {
        expression.firstMatch(in: text.text, range: NSRange(location: 0, length: text.length))
    }
}
