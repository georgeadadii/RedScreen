import Foundation

/// A named detection configuration. Holds configuration only: thresholds, which built-in rules
/// are off, placeholder values to ignore, and custom rules. Never screenshot content, OCR text,
/// matched values, or history, so a profile is safe to read, share, and store as plain text.
public struct DetectionProfile: Equatable, Hashable, Sendable {
    public var name: String
    /// Percent confidence (0–100) at or above which a finding is `likely` (included by default).
    public var likelyThreshold: Int
    /// Percent confidence at or above which a finding is shown for review.
    public var reviewThreshold: Int
    /// Built-in rule IDs that are turned off.
    public var disabledRules: Set<String>
    /// Values that are ignored when a finding's value equals one of them (case-insensitive),
    /// such as a team's documented placeholder token.
    public var placeholders: [String]
    public var customRules: [CustomDetectionRule]

    public init(
        name: String,
        likelyThreshold: Int,
        reviewThreshold: Int,
        disabledRules: Set<String> = [],
        placeholders: [String] = [],
        customRules: [CustomDetectionRule] = []
    ) {
        self.name = name
        self.likelyThreshold = likelyThreshold
        self.reviewThreshold = reviewThreshold
        self.disabledRules = disabledRules
        self.placeholders = placeholders
        self.customRules = customRules
    }

    // MARK: - Built-in profiles

    /// The default: exactly the Phase 1 detector (likely ≥ 70, review ≥ 35, every rule on).
    public static let balanced = DetectionProfile(name: "Balanced", likelyThreshold: 70, reviewThreshold: 35)

    /// Higher recall: more findings are redacted by default and fewer are dropped, at the cost of
    /// more false positives to exclude by hand.
    public static let conservative = DetectionProfile(name: "Conservative", likelyThreshold: 55, reviewThreshold: 25)

    public static let builtIns: [DetectionProfile] = [.balanced, .conservative]

    public var isBuiltIn: Bool { Self.builtIns.contains(self) }

    /// What the profile trades off, for the profile picker.
    public var explanation: String {
        switch self {
        case .balanced:
            "The default. Redacts findings at 70% confidence or higher and asks you to review those from 35%. "
                + "Fewer false positives; a few weak findings are left for you to decide."
        case .conservative:
            "Higher recall. Redacts from 55% and asks you to review from 25%, so more borderline values are "
                + "covered or shown, at the cost of more false positives to exclude by hand."
        default:
            "A custom profile. Thresholds: redact from \(likelyThreshold)%, review from \(reviewThreshold)%. "
                + "\(customRules.count) custom rules, \(disabledRules.count) built-in rules off, "
                + "\(placeholders.count) placeholder exclusions."
        }
    }

    // MARK: - Coverage

    /// Ways this profile may show *less* than the Balanced default. Each needs the user's
    /// deliberate confirmation, and each is listed in the warning.
    public var coverageReductions: [String] {
        var reasons: [String] = []
        let base = Self.balanced
        if reviewThreshold > base.reviewThreshold {
            reasons.append("Findings below \(reviewThreshold)% are hidden (the default shows them from \(base.reviewThreshold)%).")
        }
        if likelyThreshold > base.likelyThreshold {
            reasons.append("Findings below \(likelyThreshold)% are no longer redacted automatically (the default is \(base.likelyThreshold)%).")
        }
        if !disabledRules.isEmpty {
            reasons.append("\(disabledRules.count) built-in \(disabledRules.count == 1 ? "rule is" : "rules are") off: "
                           + disabledRules.sorted().joined(separator: ", ") + ".")
        }
        if !placeholders.isEmpty {
            reasons.append("Values equal to \(placeholders.count) listed \(placeholders.count == 1 ? "placeholder are" : "placeholders are") ignored.")
        }
        return reasons
    }

    public var reducesCoverage: Bool { !coverageReductions.isEmpty }

    /// The detector thresholds for this profile. Every other tuning value stays at the default.
    public var thresholds: SecretDetectionThresholds {
        var thresholds = SecretDetectionThresholds.standard
        thresholds.likelyConfidence = Double(likelyThreshold) / 100
        thresholds.reviewConfidence = Double(reviewThreshold) / 100
        return thresholds
    }
}

/// A rule in a constrained pattern language, matched by a linear-time scanner. There are no
/// regular expressions, so rules cannot backtrack, run code, or read files or the environment.
public struct CustomDetectionRule: Equatable, Hashable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        /// A token with a fixed prefix followed by characters from one set, such as `acme_` + 32
        /// letters and digits.
        case token
        /// The value assigned to one of the given key names, with `=` or `:`.
        case keyValue
    }

    public enum CharacterClass: String, CaseIterable, Sendable {
        case alphanumeric
        /// Letters, digits, `-`, and `_`.
        case alphanumericDashUnderscore
        case hex
        case digits
        /// Letters, digits, `-`, `_`, `.`, `+`, `/`, and `=`.
        case tokenCharacters

        func contains(_ scalar: Unicode.Scalar) -> Bool {
            let v = scalar.value
            let alpha = (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v)
            let digit = (0x30...0x39).contains(v)
            switch self {
            case .alphanumeric: return alpha || digit
            case .alphanumericDashUnderscore: return alpha || digit || scalar == "-" || scalar == "_"
            case .hex: return digit || (0x41...0x46).contains(v) || (0x61...0x66).contains(v)
            case .digits: return digit
            case .tokenCharacters: return alpha || digit || "-_.+/=".unicodeScalars.contains(scalar)
            }
        }
    }

    /// `custom.` followed by lowercase letters, digits, and `-`.
    public var id: String
    public var kind: Kind
    /// For `.token`.
    public var prefix: String
    public var characters: CharacterClass
    /// For `.keyValue`: key names, matched whole and case-insensitively.
    public var keys: [String]
    /// Length of the token body (after the prefix) or of the assigned value.
    public var minimumLength: Int
    public var maximumLength: Int
    /// Percent confidence (0–100) for matches.
    public var confidence: Int

    public init(
        id: String,
        kind: Kind,
        prefix: String = "",
        characters: CharacterClass = .alphanumeric,
        keys: [String] = [],
        minimumLength: Int,
        maximumLength: Int,
        confidence: Int
    ) {
        self.id = id
        self.kind = kind
        self.prefix = prefix
        self.characters = characters
        self.keys = keys
        self.minimumLength = minimumLength
        self.maximumLength = maximumLength
        self.confidence = confidence
    }
}

/// The built-in rules a profile can turn off.
public enum BuiltInDetectionRule {
    /// Every native rule ID, without the `.wrapped` suffix (turning a rule off also turns off its
    /// wrapped-line form).
    public static let ids: [String] = [
        "assignment.env", "assignment.credential", "assignment.weak-context",
        "bearer.token", "bearer.truncated",
        "connection-string.password", "connection-string.username-only",
        "high-entropy.contextual", "label.table", "prose.quoted-credential",
        "private-key.block", "private-key.encrypted-block",
        "provider.anthropic-key", "provider.aws-access-key-id", "provider.github-fine-grained-token",
        "provider.github-token", "provider.gitlab-token", "provider.google-api-key", "provider.jwt",
        "provider.npm-token", "provider.openai-key", "provider.slack-token", "provider.stripe-live-key",
        "provider.stripe-test-key",
    ]

    /// The base rule ID of a native finding, for matching against `disabledRules`.
    public static func base(of ruleID: String) -> String {
        ruleID.hasSuffix(".wrapped") ? String(ruleID.dropLast(".wrapped".count)) : ruleID
    }
}

/// Where the user's own profiles (as plain-text profile JSON) and the selected profile name are kept.
public protocol DetectionProfileStore: AnyObject {
    var savedProfileDocuments: [String] { get set }
    var selectedProfileName: String? { get set }
}
