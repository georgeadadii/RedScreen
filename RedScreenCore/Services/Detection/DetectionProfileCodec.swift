import Foundation

/// Reads, validates, and writes detection profiles as plain-text JSON.
///
/// ```json
/// {"format": "redscreen-detection-profile", "version": 1, "name": "Team",
///  "thresholds": {"likely": 70, "review": 35},
///  "disabledRules": ["provider.stripe-test-key"],
///  "placeholders": ["team-placeholder-token"],
///  "customRules": [{"id": "custom.team-token", "kind": "token", "prefix": "team_",
///                   "characters": "alphanumeric", "minLength": 24, "maxLength": 48, "confidence": 90}]}
/// ```
///
/// Every problem is reported with an actionable message; nothing invalid is ever partly applied.
public enum DetectionProfileCodec {
    public static let format = "redscreen-detection-profile"
    public static let currentVersion = 1
    /// Versions this build reads. A newer file fails with an "update RedScreen" message.
    public static let supportedVersions: ClosedRange<Int> = 1...1

    public static let maximumBytes = 64 * 1024
    public static let maximumCustomRules = 64
    public static let maximumPlaceholders = 256
    public static let maximumKeysPerRule = 16

    // MARK: - Reading

    public static func decode(_ data: Data) throws -> DetectionProfile {
        guard data.count <= maximumBytes else {
            throw ProfileError(["The profile file is larger than \(maximumBytes / 1024) KB. Profiles hold settings only, so this is not a profile."])
        }
        guard let object = try? JSONSerialization.jsonObject(with: data), let root = object as? [String: Any] else {
            throw ProfileError(["The file is not valid JSON."])
        }
        guard root["format"] as? String == format else {
            throw ProfileError(["This is not a RedScreen detection profile (missing \"format\": \"\(format)\")."])
        }
        guard let version = root["version"] as? Int else {
            throw ProfileError(["The profile has no \"version\" number."])
        }
        guard version <= supportedVersions.upperBound else {
            throw ProfileError(["This profile uses version \(version), made by a newer RedScreen. Update RedScreen to use it."])
        }
        guard supportedVersions.contains(version) else {
            throw ProfileError(["Profile version \(version) is not supported."])
        }
        let migrated = try migrate(root, from: version)
        let profile = try parse(migrated)
        let issues = validate(profile)
        guard issues.isEmpty else { throw ProfileError(issues) }
        return profile
    }

    /// Upgrades an older document to the current version, one step at a time. Version 1 is the
    /// first version, so there is nothing to migrate yet; each future version adds a step here.
    static func migrate(_ root: [String: Any], from version: Int) throws -> [String: Any] {
        var document = root
        var current = version
        while current < currentVersion {
            switch current {
            default:
                throw ProfileError(["Profile version \(current) cannot be upgraded."])
            }
            current += 1
        }
        document["version"] = currentVersion
        return document
    }

    private static let allowedKeys: Set<String> = ["format", "version", "name", "thresholds", "disabledRules", "placeholders", "customRules"]
    private static let allowedRuleKeys: Set<String> = ["id", "kind", "prefix", "characters", "keys", "minLength", "maxLength", "confidence"]

    private static func parse(_ root: [String: Any]) throws -> DetectionProfile {
        var issues: [String] = []
        let unknown = Set(root.keys).subtracting(allowedKeys)
        if !unknown.isEmpty { issues.append("Unknown settings: \(unknown.sorted().joined(separator: ", ")).") }
        let name = root["name"] as? String ?? ""
        let thresholds = root["thresholds"] as? [String: Any] ?? [:]
        let likely = thresholds["likely"] as? Int
        let review = thresholds["review"] as? Int
        if likely == nil || review == nil { issues.append("\"thresholds\" needs whole-number \"likely\" and \"review\" percentages.") }
        let disabled = root["disabledRules"] as? [String] ?? []
        if root["disabledRules"] != nil, root["disabledRules"] as? [String] == nil {
            issues.append("\"disabledRules\" must be a list of rule IDs.")
        }
        let placeholders = root["placeholders"] as? [String] ?? []
        if root["placeholders"] != nil, root["placeholders"] as? [String] == nil {
            issues.append("\"placeholders\" must be a list of text values.")
        }
        var rules: [CustomDetectionRule] = []
        if let entries = root["customRules"] {
            guard let list = entries as? [[String: Any]] else {
                throw ProfileError(issues + ["\"customRules\" must be a list of rules."])
            }
            if list.count > maximumCustomRules {
                throw ProfileError(issues + ["A profile can have at most \(maximumCustomRules) custom rules; this one has \(list.count)."])
            }
            for (index, entry) in list.enumerated() {
                let label = (entry["id"] as? String).map { "Rule \($0)" } ?? "Rule \(index + 1)"
                let extra = Set(entry.keys).subtracting(allowedRuleKeys)
                if !extra.isEmpty { issues.append("\(label): unknown fields \(extra.sorted().joined(separator: ", ")).") }
                guard let kindName = entry["kind"] as? String, let kind = CustomDetectionRule.Kind(rawValue: kindName) else {
                    issues.append("\(label): \"kind\" must be \"token\" or \"keyValue\".")
                    continue
                }
                let charactersName = entry["characters"] as? String ?? CustomDetectionRule.CharacterClass.alphanumeric.rawValue
                guard let characters = CustomDetectionRule.CharacterClass(rawValue: charactersName) else {
                    issues.append("\(label): \"characters\" must be one of "
                                  + CustomDetectionRule.CharacterClass.allCases.map(\.rawValue).joined(separator: ", ") + ".")
                    continue
                }
                guard let minimum = entry["minLength"] as? Int, let maximum = entry["maxLength"] as? Int,
                      let confidence = entry["confidence"] as? Int else {
                    issues.append("\(label): \"minLength\", \"maxLength\", and \"confidence\" must be whole numbers.")
                    continue
                }
                rules.append(CustomDetectionRule(
                    id: entry["id"] as? String ?? "", kind: kind, prefix: entry["prefix"] as? String ?? "",
                    characters: characters, keys: entry["keys"] as? [String] ?? [],
                    minimumLength: minimum, maximumLength: maximum, confidence: confidence
                ))
            }
        }
        guard issues.isEmpty, let likely, let review else { throw ProfileError(issues) }
        return DetectionProfile(name: name, likelyThreshold: likely, reviewThreshold: review,
                                disabledRules: Set(disabled), placeholders: placeholders, customRules: rules)
    }

    // MARK: - Validation

    private static let keyCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-")
    private static let idCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")

    /// Every problem with the profile, as messages that say what to change. Empty when valid.
    public static func validate(_ profile: DetectionProfile) -> [String] {
        var issues: [String] = []
        let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name.count > 60 { issues.append("Give the profile a name of 1–60 characters.") }
        if DetectionProfile.builtIns.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }),
           !profile.isBuiltIn {
            issues.append("\"\(name)\" is a built-in profile name. Choose another name.")
        }
        if !(1...100).contains(profile.likelyThreshold) || !(1...100).contains(profile.reviewThreshold) {
            issues.append("Thresholds must be whole percentages from 1 to 100.")
        } else if profile.reviewThreshold > profile.likelyThreshold {
            issues.append("The review threshold (\(profile.reviewThreshold)%) must not be above the redact threshold (\(profile.likelyThreshold)%).")
        }
        let unknownRules = profile.disabledRules.subtracting(BuiltInDetectionRule.ids)
        if !unknownRules.isEmpty {
            issues.append("Unknown built-in rules: \(unknownRules.sorted().joined(separator: ", ")).")
        }
        if profile.placeholders.count > maximumPlaceholders {
            issues.append("A profile can list at most \(maximumPlaceholders) placeholders.")
        }
        for placeholder in profile.placeholders where placeholder.trimmingCharacters(in: .whitespaces).count < 3
            || placeholder.count > 64 {
            issues.append("Placeholder \"\(placeholder.prefix(20))\" must be 3–64 characters.")
        }
        if Set(profile.placeholders.map { $0.lowercased() }).count != profile.placeholders.count {
            issues.append("Each placeholder may be listed only once.")
        }

        var seen: Set<String> = []
        for (index, rule) in profile.customRules.enumerated() {
            let label = rule.id.isEmpty ? "Custom rule \(index + 1)" : "Rule \(rule.id)"
            let slug = rule.id.hasPrefix("custom.") ? String(rule.id.dropFirst("custom.".count)) : ""
            if slug.isEmpty || slug.count > 48 || !slug.unicodeScalars.allSatisfy(idCharacters.contains) {
                issues.append("\(label): the ID must be \"custom.\" followed by 1–48 lowercase letters, digits, or hyphens.")
            }
            if !seen.insert(rule.id).inserted { issues.append("\(label): another custom rule has the same ID.") }
            if !(1...100).contains(rule.confidence) {
                issues.append("\(label): confidence must be a whole percentage from 1 to 100.")
            } else if rule.confidence < profile.reviewThreshold {
                issues.append("\(label): its confidence (\(rule.confidence)%) is below the review threshold, so it would never show anything.")
            }
            if rule.minimumLength < 8 || rule.minimumLength > 256 {
                issues.append("\(label): the minimum length must be 8–256, so short words are not matched.")
            }
            if rule.maximumLength < rule.minimumLength || rule.maximumLength > 512 {
                issues.append("\(label): the maximum length must be at least the minimum and at most 512.")
            }
            switch rule.kind {
            case .token:
                if rule.prefix.count < 3 || rule.prefix.count > 32 || !rule.prefix.unicodeScalars.allSatisfy(keyCharacters.contains) {
                    issues.append("\(label): the prefix must be 3–32 letters, digits, \"_\", \".\", or \"-\", so it cannot match everywhere.")
                }
                if !rule.keys.isEmpty { issues.append("\(label): token rules use a prefix, not keys.") }
            case .keyValue:
                if rule.keys.isEmpty || rule.keys.count > maximumKeysPerRule {
                    issues.append("\(label): list 1–\(maximumKeysPerRule) key names.")
                }
                for key in rule.keys where key.count < 2 || key.count > 64 || !key.unicodeScalars.allSatisfy(keyCharacters.contains) {
                    issues.append("\(label): key \"\(key.prefix(20))\" must be 2–64 letters, digits, \"_\", \".\", or \"-\".")
                }
                if Set(rule.keys.map { $0.lowercased() }).count != rule.keys.count {
                    issues.append("\(label): each key may be listed only once.")
                }
                if !rule.prefix.isEmpty { issues.append("\(label): key/value rules use keys, not a prefix.") }
            }
            if BuiltInDetectionRule.ids.contains(rule.id) { issues.append("\(label): this ID belongs to a built-in rule.") }
        }
        // Two token rules with the same prefix and character set would report the same values.
        var signatures: Set<String> = []
        for rule in profile.customRules where rule.kind == .token {
            if !signatures.insert("\(rule.prefix.lowercased())|\(rule.characters.rawValue)").inserted {
                issues.append("Rule \(rule.id): another token rule already matches prefix \"\(rule.prefix)\" with the same characters.")
            }
        }
        return issues
    }

    // MARK: - Writing

    /// Pretty-printed JSON with sorted keys: stable, diffable, and readable in any editor.
    public static func encode(_ profile: DetectionProfile) throws -> Data {
        let issues = validate(profile)
        guard issues.isEmpty else { throw ProfileError(issues) }
        let rules: [[String: Any]] = profile.customRules.map { rule in
            var entry: [String: Any] = [
                "id": rule.id, "kind": rule.kind.rawValue, "minLength": rule.minimumLength,
                "maxLength": rule.maximumLength, "confidence": rule.confidence,
            ]
            switch rule.kind {
            case .token:
                entry["prefix"] = rule.prefix
                entry["characters"] = rule.characters.rawValue
            case .keyValue:
                entry["keys"] = rule.keys
            }
            return entry
        }
        let root: [String: Any] = [
            "format": format,
            "version": currentVersion,
            "name": profile.name.trimmingCharacters(in: .whitespacesAndNewlines),
            "thresholds": ["likely": profile.likelyThreshold, "review": profile.reviewThreshold],
            "disabledRules": profile.disabledRules.sorted(),
            "placeholders": profile.placeholders,
            "customRules": rules,
        ]
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}

/// Why a profile was rejected, as messages that say what to change.
public struct ProfileError: Error, Equatable, Sendable {
    public let issues: [String]

    public init(_ issues: [String]) {
        self.issues = issues
    }
}
