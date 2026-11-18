import Foundation

/// The allowlist that every fixture value must satisfy to prove it is synthetic.
///
/// Rules (see docs/TEST_FIXTURES.md):
/// - Sensitive and ambiguous spans contain a reserved marker: `RSFAKE`, `rsfake`, or `EXAMPLE`.
/// - Any substring shaped like a real credential (provider token prefixes, bearer values,
///   passwords embedded in URLs, JWTs) contains a marker.
/// - Private-key armor only appears in fixtures whose key bodies carry a marker.
/// - Email domains and URL hosts are reserved (`localhost`, `*.test`, `*.example`, `*.invalid`,
///   `*.localhost`, `example.com`/`.org`/`.net`); IPv4 addresses are loopback or RFC 5737.
/// - No user home paths and no supplied local account identities appear anywhere.
///
/// Violations describe the fixture, text box, span, and rule only. They never echo the text.
struct SyntheticValuePolicy {
    enum Rule: String, CaseIterable, Sendable {
        case missingSyntheticFlag
        case sensitiveValueWithoutMarker
        case credentialShapeWithoutMarker
        case privateKeyWithoutSyntheticBody
        case unreservedEmailDomain
        case unreservedHost
        case unreservedIPv4Address
        case userHomePath
        case localAccountIdentity
    }

    struct Violation: Equatable, Sendable, CustomStringConvertible {
        let fixtureID: String
        let textBoxID: String?
        let spanID: String?
        let rule: Rule

        var description: String {
            var parts = ["fixture \(fixtureID)"]
            if let textBoxID { parts.append("text box \(textBoxID)") }
            if let spanID { parts.append("span \(spanID)") }
            return "\(rule.rawValue): " + parts.joined(separator: ", ")
        }
    }

    static let markers = ["RSFAKE", "rsfake", "EXAMPLE"]
    static let reservedDomainSuffixes = [
        ".test", ".example", ".invalid", ".localhost",
        ".example.com", ".example.org", ".example.net",
    ]
    static let reservedDomains = ["localhost", "example.com", "example.org", "example.net"]

    /// Identities that must never appear, such as the local account running the tests.
    let forbiddenIdentities: [String]

    init(forbiddenIdentities: [String] = []) {
        self.forbiddenIdentities = forbiddenIdentities
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 4 }
    }

    static func containsMarker(_ text: String) -> Bool {
        markers.contains { text.contains($0) }
    }

    func violations(in groundTruth: FixtureGroundTruth) -> [Violation] {
        var violations: [Violation] = []
        let id = groundTruth.id

        if !groundTruth.syntheticTestData {
            violations.append(Violation(
                fixtureID: id, textBoxID: nil, spanID: nil, rule: .missingSyntheticFlag
            ))
        }

        for span in groundTruth.spans where span.expectation != .benign {
            let text = span.segments.compactMap { segment -> String? in
                guard let box = groundTruth.textBox(id: segment.textBoxID) else { return nil }
                let utf16 = Array(box.text.utf16)
                let end = min(utf16.count, segment.utf16Offset + segment.utf16Length)
                guard segment.utf16Offset >= 0, segment.utf16Offset < end else { return nil }
                return String(decoding: utf16[segment.utf16Offset..<end], as: UTF16.self)
            }.joined()
            if !Self.containsMarker(text) {
                violations.append(Violation(
                    fixtureID: id, textBoxID: nil, spanID: span.id,
                    rule: .sensitiveValueWithoutMarker
                ))
            }
        }

        let hasPrivateKeyArmor = groundTruth.textBoxes.contains {
            Self.matches(of: #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#, in: $0.text).isEmpty == false
        }
        if hasPrivateKeyArmor && !groundTruth.textBoxes.contains(where: {
            Self.containsMarker($0.text) && !$0.text.hasPrefix("-----")
        }) {
            violations.append(Violation(
                fixtureID: id, textBoxID: nil, spanID: nil, rule: .privateKeyWithoutSyntheticBody
            ))
        }

        for box in groundTruth.textBoxes {
            for rule in textViolations(in: box.text) {
                violations.append(Violation(
                    fixtureID: id, textBoxID: box.id, spanID: nil, rule: rule
                ))
            }
        }
        return violations
    }

    /// Rules that apply to any single line of fixture text.
    func textViolations(in text: String) -> [Rule] {
        var rules: [Rule] = []

        let credentialShapes = [
            #"AKIA[0-9A-Z]{16}"#,
            #"gh[pousr]_[A-Za-z0-9]{20,}"#,
            #"xox[abprs]-[A-Za-z0-9-]{8,}"#,
            #"sk_live_[A-Za-z0-9]{8,}"#,
            #"(?i)bearer\s+[A-Za-z0-9._~+/=-]{8,}"#,
            #"[A-Za-z][A-Za-z0-9+.-]*://[^\s:/@]*:[^\s@/]+@"#,
            #"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{4,}"#,
        ]
        if credentialShapes.contains(where: { pattern in
            Self.matches(of: pattern, in: text).contains { !Self.containsMarker($0) }
        }) {
            rules.append(.credentialShapeWithoutMarker)
        }

        let emailDomains = Self.captures(
            of: #"[A-Za-z0-9._%+-]+@([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,})"#,
            in: text
        )
        if emailDomains.contains(where: { !Self.isReservedHost($0) }) {
            rules.append(.unreservedEmailDomain)
        }

        let hosts = Self.captures(
            of: #"://(?:[^\s/@]*@)?([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+|localhost)"#,
            in: text
        )
        if hosts.contains(where: { !Self.isReservedHost($0) && Self.ipv4Octets($0) == nil }) {
            rules.append(.unreservedHost)
        }

        let addresses = Self.matches(of: #"(?<![\d.])\d{1,3}(?:\.\d{1,3}){3}(?![\d.])"#, in: text)
        if addresses.contains(where: { address in
            guard let octets = Self.ipv4Octets(address) else { return false }
            return !Self.isReservedIPv4(octets)
        }) {
            rules.append(.unreservedIPv4Address)
        }

        if text.contains("/Users/") || text.contains("/home/") {
            rules.append(.userHomePath)
        }

        if forbiddenIdentities.contains(where: {
            text.range(of: $0, options: [.caseInsensitive]) != nil
        }) {
            rules.append(.localAccountIdentity)
        }
        return rules
    }

    // MARK: - Helpers

    static func isReservedHost(_ host: String) -> Bool {
        let host = host.lowercased()
        return reservedDomains.contains(host)
            || reservedDomainSuffixes.contains { host.hasSuffix($0) }
    }

    static func ipv4Octets(_ text: String) -> [Int]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return nil }
        return octets
    }

    static func isReservedIPv4(_ octets: [Int]) -> Bool {
        octets[0] == 127
            || octets == [0, 0, 0, 0]
            || octets.prefix(3) == [192, 0, 2]
            || octets.prefix(3) == [198, 51, 100]
            || octets.prefix(3) == [203, 0, 113]
    }

    private static func matches(of pattern: String, in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            preconditionFailure("Invalid synthetic-value policy pattern")
        }
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    private static func captures(of pattern: String, in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            preconditionFailure("Invalid synthetic-value policy pattern")
        }
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }
}
