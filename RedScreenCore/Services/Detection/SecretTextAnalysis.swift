import Foundation

// Text helpers for the secret detector. Everything here is pure, deterministic, and bounded.

/// OCR text with conservative punctuation normalization that preserves UTF-16 offsets.
///
/// Only one-unit-for-one-unit substitutions are made (Unicode dashes to `-`, curly quotes to
/// straight quotes, non-breaking spaces to spaces, full-width `:`/`=`), so every offset in the
/// normalized string is also an offset into the original observation text. The original text is
/// never modified.
struct NormalizedLine {
    let text: String
    let nsText: NSString

    init(_ original: String, maximumUTF16: Int) {
        var units = Array(original.utf16.prefix(maximumUTF16))
        if let last = units.last, UTF16.isLeadSurrogate(last) { units.removeLast() }
        for index in units.indices {
            units[index] = Self.normalize(units[index])
        }
        // Invalid sequences decode to U+FFFD, which is also a single UTF-16 unit.
        text = String(decoding: units, as: UTF16.self)
        nsText = text as NSString
    }

    var length: Int { nsText.length }

    func substring(_ range: NSRange) -> String { nsText.substring(with: range) }

    private static func normalize(_ unit: UTF16.CodeUnit) -> UTF16.CodeUnit {
        switch unit {
        case 0x2010...0x2015, 0x2212, 0xFE58, 0xFE63, 0xFF0D: 0x2D  // dashes → -
        case 0x2018, 0x2019, 0x201A, 0x201B, 0x2032: 0x27  // single quotes → '
        case 0x201C, 0x201D, 0x201E, 0x2033: 0x22  // double quotes → "
        case 0x00A0, 0x2007, 0x202F, 0x2009, 0x200A: 0x20  // spaces
        case 0xFF1A: 0x3A  // full-width colon
        case 0xFF1D: 0x3D  // full-width equals
        default: unit
        }
    }
}

/// How strongly a label or key name implies the value after it is secret.
enum KeywordStrength: Comparable {
    case none
    case weak
    case medium
    case strong
}

struct KeyClassification {
    let strength: KeywordStrength
    /// The key describes a hint about a secret rather than the secret itself.
    let isHint: Bool
}

enum SecretKeywords {
    static let strongWords: Set<String> = [
        "password", "passwd", "pwd", "pass", "passphrase", "passcode", "secret", "secrets",
        "credential", "credentials", "creds", "apikey", "privatekey", "secretkey",
        "clientsecret",
    ]
    static let strongKeyQualifiers: Set<String> = [
        "api", "private", "signing", "secret", "encryption", "master", "access", "client",
        "service", "app", "webhook", "deploy", "license", "auth",
    ]
    static let strongTokenQualifiers: Set<String> = [
        "access", "refresh", "auth", "api", "session", "bearer", "github", "gitlab", "slack",
        "npm", "deploy", "personal", "oauth", "bot", "service",
    ]
    static let mediumWords: Set<String> = [
        "token", "tokens", "key", "auth", "authorization", "cookie", "otp",
    ]
    static let weakWords: Set<String> = ["salt", "nonce", "seed", "id", "identifier", "signature"]
    /// A final component from this set means the key describes metadata, not a secret.
    static let excludedFinalWords: Set<String> = [
        "ttl", "expiry", "expires", "expiration", "length", "len", "min", "max", "count", "type",
        "name", "url", "uri", "host", "hostname", "port", "endpoint", "path", "file", "dir",
        "enabled", "required", "policy", "scopes", "scope", "header", "sha", "hash", "checksum",
        "digest", "integrity", "commit", "ref", "version", "region", "user", "username",
        "email", "level", "mode", "format", "algorithm", "alg", "size", "timeout", "prefix",
        "suffix", "label", "description", "rotation", "date", "created", "updated", "status",
        "fingerprint", "env", "flags", "flag",
    ]
    static let connectorWords: Set<String> = ["is", "was", "are", "be", "to", "set", "now"]
    static let proseContextWords: [String] = [
        "password", "passcode", "passphrase", "credential", "login", "log in", "sign in",
        "signin", "reset",
    ]

    /// Classifies a key or label such as `DB_PASSWORD`, `clientSecret`, or `Secret access key`.
    static func classify(_ phrase: String) -> KeyClassification {
        let words = components(of: phrase)
        guard let last = words.last else { return KeyClassification(strength: .none, isHint: false) }
        let isHint = words.contains("hint")
        if !isHint, excludedFinalWords.contains(last) {
            return KeyClassification(strength: .none, isHint: false)
        }

        let previous = words.count >= 2 ? words[words.count - 2] : nil
        if words.contains(where: strongWords.contains)
            || (last == "key" && previous.map(strongKeyQualifiers.contains) == true)
            || (last == "token" && previous.map(strongTokenQualifiers.contains) == true) {
            return KeyClassification(strength: .strong, isHint: isHint)
        }
        if words.contains(where: mediumWords.contains) {
            return KeyClassification(strength: .medium, isHint: isHint)
        }
        if weakWords.contains(last) {
            return KeyClassification(strength: .weak, isHint: isHint)
        }
        return KeyClassification(strength: .none, isHint: isHint)
    }

    /// Lower-cased words of a key, splitting on punctuation, spaces, and camelCase, with
    /// common OCR digit/letter confusions inside words undone (`PASSW0RD` → `password`).
    static func components(of phrase: String) -> [String] {
        var words: [String] = []
        var current = ""
        var previousWasLower = false
        for character in phrase {
            if character.isLetter || character.isNumber {
                if character.isUppercase, previousWasLower, !current.isEmpty {
                    words.append(current)
                    current = ""
                }
                current.append(character)
                previousWasLower = character.isLowercase
            } else {
                if !current.isEmpty { words.append(current) }
                current = ""
                previousWasLower = false
            }
        }
        if !current.isEmpty { words.append(current) }
        return words.map { word in
            let lowered = word.lowercased()
            guard lowered.contains(where: \.isLetter) else { return lowered }
            return String(lowered.map { character -> Character in
                switch character {
                case "0": "o"
                case "1": "l"
                case "5": "s"
                case "@": "a"
                default: character
                }
            })
        }
    }
}

/// Shape analysis for candidate values.
enum ValueAnalysis {
    enum Kind: Equatable {
        /// Nothing secret-like: empty, placeholder, numeric, boolean, fully masked, URL.
        case notSecret
        /// Partially masked or UUID-shaped: surface for review only.
        case reviewOnly
        /// Plain lower-case word: unlikely, scored low.
        case plainWord
        case candidate
    }

    static let placeholderWords: Set<String> = [
        "changeme", "change_me", "changeit", "password", "passwd", "secret", "token", "apikey",
        "api_key", "xxx", "todo", "tbd", "none", "null", "nil", "undefined", "redacted",
        "placeholder", "dummy", "example", "sample", "true", "false", "yes", "no", "on", "off",
        "hidden", "masked", "empty", "default",
    ]

    static func kind(of value: String) -> Kind {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .notSecret }
        let lower = trimmed.lowercased()
        if placeholderWords.contains(lower) { return .notSecret }
        if trimmed.contains("://") { return .notSecret }
        if isPlaceholderShape(trimmed) { return .notSecret }

        let maskCharacters: Set<Character> = ["*", "\u{2022}", "\u{25CF}", "\u{00B7}", "#"]
        let masked = trimmed.filter { maskCharacters.contains($0) }.count
        // Mostly masked values (`ghp_****…`) are already redacted by the source.
        if masked * 2 >= trimmed.count { return .notSecret }
        if trimmed.allSatisfy({ $0 == "x" || $0 == "X" }) { return .notSecret }
        if masked >= 3, hasRun(of: maskCharacters, length: 3, in: trimmed) { return .reviewOnly }

        if trimmed.allSatisfy({ $0.isNumber || ".,:_-+ ".contains($0) }) { return .notSecret }
        if isUUID(trimmed) { return .reviewOnly }
        if trimmed.allSatisfy({ $0.isLowercase && $0.isLetter }) { return .plainWord }
        return .candidate
    }

    static func isPlaceholderShape(_ value: String) -> Bool {
        let lower = value.lowercased()
        if (value.hasPrefix("<") && value.hasSuffix(">"))
            || (value.hasPrefix("${") && value.hasSuffix("}"))
            || (value.hasPrefix("{{") && value.hasSuffix("}}"))
            || (value.hasPrefix("%") && value.hasSuffix("%") && value.count > 2)
            || value.hasPrefix("\\(")
            || value.hasPrefix("$") {
            return true
        }
        return lower.hasPrefix("your-") || lower.hasPrefix("your_") || lower.hasSuffix("-here")
            || lower.hasSuffix("_here") || lower.contains("example-") || lower == "..."
    }

    static func isUUID(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.map(\.count) == [8, 4, 4, 4, 12] else { return false }
        return parts.allSatisfy { $0.allSatisfy(\.isHexDigit) }
    }

    static func isHexOnly(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy(\.isHexDigit)
    }

    /// Integrity strings such as `sha512-…` or `sha256:…`.
    static func isDigestShaped(_ value: String) -> Bool {
        let lower = value.lowercased()
        return ["sha1-", "sha256-", "sha384-", "sha512-", "sha1:", "sha256:", "sha512:", "md5:"]
            .contains { lower.hasPrefix($0) }
    }

    static func characterClassCount(_ value: String) -> Int {
        var lower = false
        var upper = false
        var digit = false
        var symbol = false
        for character in value {
            if character.isLowercase { lower = true }
            else if character.isUppercase { upper = true }
            else if character.isNumber { digit = true }
            else if !character.isWhitespace { symbol = true }
        }
        return [lower, upper, digit, symbol].filter { $0 }.count
    }

    /// Shannon entropy in bits per character.
    static func entropy(_ value: String) -> Double {
        guard !value.isEmpty else { return 0 }
        var counts: [Character: Int] = [:]
        for character in value { counts[character, default: 0] += 1 }
        let total = Double(value.count)
        return counts.values.reduce(0) { sum, count in
            let probability = Double(count) / total
            return sum - probability * log2(probability)
        }
    }

    /// How secret-like a value looks on its own, in `0...1`.
    static func strength(of value: String, thresholds: SecretDetectionThresholds) -> Double {
        let length = value.count
        guard length >= thresholds.minimumValueLength else { return 0 }
        let classes = characterClassCount(value)
        var score = 0.4
        if classes >= 3 { score += 0.2 }
        if classes == 4 || entropy(value) >= thresholds.highEntropyBitsPerCharacter { score += 0.2 }
        if length >= thresholds.longValueLength { score += 0.2 }
        return min(1, score)
    }

    /// Random-looking: long, high entropy, mixing letters and digits.
    static func isHighEntropy(_ value: String, thresholds: SecretDetectionThresholds) -> Bool {
        value.count >= thresholds.highEntropyMinimumLength
            && entropy(value) >= thresholds.highEntropyBitsPerCharacter
            && value.contains(where: \.isLetter) && value.contains(where: \.isNumber)
            && !isUUID(value) && !isDigestShaped(value)
    }

    private static func hasRun(of set: Set<Character>, length: Int, in value: String) -> Bool {
        var run = 0
        for character in value {
            run = set.contains(character) ? run + 1 : 0
            if run >= length { return true }
        }
        return false
    }
}
