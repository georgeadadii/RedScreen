import CryptoKit
import Foundation

/// Native side of the RedScreen hint protocol, version 1 (docs/VSCODE_HINT_PROTOCOL.md).
///
/// Byte-for-byte compatible with the extension's `src/protocol.ts`; both are checked against the
/// shared vectors in `Extensions/vscode/test/fixtures/protocol-vectors.json`. Every failure is
/// a `HintProtocolError` and closes the connection: the protocol fails closed.
public enum HintProtocol {
    public static let name = "redscreen-hints"
    public static let version = 1
    public static let maximumFrameBytes = 16 * 1024
    public static let maximumHintsPerMessage = 64
    /// A hints message is valid for at most this long after it was sent.
    public static let hintLifetimeMilliseconds: Int64 = 30_000
    public static let clockSkewMilliseconds: Int64 = 2_000
    public static let keyLength = 32
    public static let nonceLength = 16

    /// Rule IDs a hint may carry: the native detector's IDs that the extension also emits.
    public static let ruleIDs: Set<String> = [
        "provider.github-token", "provider.github-fine-grained-token", "provider.gitlab-token",
        "provider.slack-token", "provider.stripe-live-key", "provider.stripe-test-key",
        "provider.google-api-key", "provider.npm-token", "provider.anthropic-key", "provider.openai-key",
        "provider.jwt", "provider.aws-access-key-id", "private-key.block", "private-key.encrypted-block",
        "connection-string.password", "bearer.token", "bearer.truncated", "assignment.env",
        "assignment.credential",
    ]

    // MARK: - Keys

    public enum Direction: String, Sendable {
        case clientToServer = "client-to-server"
        case serverToClient = "server-to-client"
    }

    static func hmac(_ key: Data, _ label: String, _ parts: Data...) -> Data {
        var mac = HMAC<SHA256>(key: SymmetricKey(data: key))
        mac.update(data: Data("rs-hints-v1/\(label)".utf8))
        for part in parts { mac.update(data: part) }
        return Data(mac.finalize())
    }

    public static func serverProof(key: Data, session: Data, clientNonce: Data, serverNonce: Data) -> Data {
        hmac(key, "server", session, clientNonce, serverNonce)
    }

    public static func clientProof(key: Data, session: Data, clientNonce: Data, serverNonce: Data) -> Data {
        hmac(key, "client", session, serverNonce, clientNonce)
    }

    public static func connectionKey(
        key: Data, session: Data, clientNonce: Data, serverNonce: Data, direction: Direction
    ) -> Data {
        hmac(key, "conn/\(direction.rawValue)", session, clientNonce, serverNonce)
    }

    public static func digestKey(key: Data, session: Data) -> Data {
        hmac(key, "digest", session)
    }

    // MARK: - Values

    /// NFKC; split into lines; trim each; drop empty lines; join with "\n"; remove one pair of
    /// matching surrounding quotes. Matches the extension's `normalizeValue`.
    public static func normalize(_ value: String) -> String {
        let lines = value.precomposedStringWithCompatibilityMapping
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: Self.trimmed) }
            .filter { !$0.isEmpty }
        let joined = lines.joined(separator: "\n")
        let scalars = Array(joined.unicodeScalars)
        if scalars.count >= 2, let first = scalars.first, ["\"", "'", "`"].contains(first), scalars.last == first {
            return String(String.UnicodeScalarView(scalars.dropFirst().dropLast()))
        }
        return joined
    }

    /// JavaScript's `String.prototype.trim` set: whitespace, line terminators, and U+FEFF.
    private static let trimmed = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))

    /// `base64url(HMAC(digestKey, rule ‖ 0x00 ‖ normalize(value)))`.
    public static func digest(digestKey: Data, rule: String, value: String) -> Data {
        var mac = HMAC<SHA256>(key: SymmetricKey(data: digestKey))
        mac.update(data: Data(rule.utf8))
        mac.update(data: Data([0]))
        mac.update(data: Data(normalize(value).utf8))
        return Data(mac.finalize())
    }

    // MARK: - Encoding

    public static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Decodes unpadded base64url of exactly `length` bytes, rejecting any non-canonical form.
    public static func decodeBase64url(_ value: Any?, length: Int) throws -> Data {
        guard let text = value as? String, !text.isEmpty,
              text.unicodeScalars.allSatisfy({ CharacterSet.base64url.contains($0) }) else {
            throw HintProtocolError.malformedMessage
        }
        var standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        standard += String(repeating: "=", count: (4 - standard.count % 4) % 4)
        guard let data = Data(base64Encoded: standard), data.count == length, base64url(data) == text else {
            throw HintProtocolError.malformedMessage
        }
        return data
    }

    /// JSON with keys sorted at every level and no whitespace, matching the extension's
    /// `canonicalJSON` (JavaScript `JSON.stringify` string escaping, integers only).
    public static func canonicalJSON(_ value: Any?) throws -> String {
        switch value {
        case nil, is NSNull:
            return "null"
        case let dictionary as [String: Any]:
            let entries = try dictionary.keys.sorted(by: utf16Less).map { key in
                "\(quoted(key)):\(try canonicalJSON(dictionary[key]))"
            }
            return "{\(entries.joined(separator: ","))}"
        case let array as [Any]:
            return "[\(try array.map { try canonicalJSON($0) }.joined(separator: ","))]"
        case let string as String:
            return quoted(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return String(try integer(number))
        case let bool as Bool:
            return bool ? "true" : "false"
        case let int as Int:
            return String(int)
        case let int as Int64:
            return String(int)
        default:
            throw HintProtocolError.malformedMessage
        }
    }

    private static func utf16Less(_ a: String, _ b: String) -> Bool {
        a.utf16.lexicographicallyPrecedes(b.utf16)
    }

    private static func quoted(_ string: String) -> String {
        var result = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\u{08}": result += "\\b"
            case "\u{0C}": result += "\\f"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case _ where scalar.value < 0x20:
                result += String(format: "\\u%04x", scalar.value)
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }

    /// A JSON integer within JavaScript's safe range. Booleans and fractions are rejected.
    static func integer(_ value: Any?) throws -> Int64 {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            throw HintProtocolError.malformedMessage
        }
        let double = number.doubleValue
        guard double.isFinite, double == double.rounded(), abs(double) <= 9_007_199_254_740_991 else {
            throw HintProtocolError.malformedMessage
        }
        return number.int64Value
    }

    public static func tag(key: Data, body: [String: Any]) throws -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(try canonicalJSON(body).utf8), using: SymmetricKey(data: key)))
    }

    // MARK: - Messages

    static let fields: [String: Set<String>] = [
        "hello": ["t", "v", "session", "nonce"],
        "challenge": ["t", "v", "nonce", "proof"],
        "auth": ["t", "v", "proof"],
        "ready": ["t", "v", "seq", "mac"],
        "hints": ["t", "v", "seq", "sent", "expires", "doc", "hints", "mac"],
        "clear": ["t", "v", "seq", "doc", "mac"],
        "ack": ["t", "v", "seq", "accepted", "mac"],
    ]

    /// Parses one frame into an object with exactly the fields its type allows.
    public static func parseFrame(_ payload: Data, expected: Set<String>) throws -> [String: Any] {
        guard payload.count <= maximumFrameBytes else { throw HintProtocolError.oversizedMessage }
        guard let object = try? JSONSerialization.jsonObject(with: payload),
              let message = object as? [String: Any] else {
            throw HintProtocolError.malformedMessage
        }
        guard let versionValue = message["v"] as? NSNumber, CFGetTypeID(versionValue) != CFBooleanGetTypeID() else {
            throw HintProtocolError.malformedMessage
        }
        guard (try? integer(versionValue)) == Int64(version) else { throw HintProtocolError.incompatibleVersion }
        guard let type = message["t"] as? String, let allowed = fields[type] else {
            throw HintProtocolError.malformedMessage
        }
        guard expected.contains(type) else { throw HintProtocolError.unexpectedMessage }
        guard Set(message.keys) == allowed else { throw HintProtocolError.malformedMessage }
        return message
    }

    /// Verifies a session message's tag in constant time and returns its body without `mac`.
    public static func verifyTag(key: Data, message: [String: Any]) throws -> [String: Any] {
        var body = message
        let mac = try decodeBase64url(body.removeValue(forKey: "mac"), length: 32)
        guard HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: Data(try canonicalJSON(body).utf8),
                                                      using: SymmetricKey(data: key)) else {
            throw HintProtocolError.authenticationFailed
        }
        return body
    }

    /// Serializes a message with its tag.
    public static func seal(key: Data, body: [String: Any]) throws -> Data {
        var message = body
        message["mac"] = base64url(try tag(key: key, body: body))
        let frame = Data(try canonicalJSON(message).utf8)
        guard frame.count <= maximumFrameBytes else { throw HintProtocolError.oversizedMessage }
        return frame
    }

    /// Field checks for a verified hints message, including freshness.
    public static func validateHints(_ body: [String: Any], now: Int64) throws -> (doc: Data, expires: Int64, hints: [EditorHint]) {
        let sent = try integer(body["sent"])
        let expires = try integer(body["expires"])
        _ = try integer(body["seq"])
        let doc = try decodeBase64url(body["doc"], length: nonceLength)
        guard sent >= 0, expires > sent, expires - sent <= hintLifetimeMilliseconds else {
            throw HintProtocolError.malformedMessage
        }
        guard sent <= now + clockSkewMilliseconds, expires > now else { throw HintProtocolError.expired }
        guard let entries = body["hints"] as? [Any], entries.count <= maximumHintsPerMessage else {
            throw HintProtocolError.malformedMessage
        }
        let hints = try entries.map { entry -> EditorHint in
            guard let hint = entry as? [String: Any], Set(hint.keys) == ["rule", "conf", "digest"],
                  let rule = hint["rule"] as? String, ruleIDs.contains(rule) else {
                throw HintProtocolError.malformedMessage
            }
            let confidence = try integer(hint["conf"])
            guard (0...100).contains(confidence) else { throw HintProtocolError.malformedMessage }
            return EditorHint(rule: rule, confidence: Int(confidence), digest: try decodeBase64url(hint["digest"], length: 32))
        }
        return (doc, expires, hints)
    }
}

public enum HintProtocolError: Error, Equatable, Sendable {
    case incompatibleVersion
    case authenticationFailed
    case malformedMessage
    case oversizedMessage
    case unexpectedMessage
    case replayedOrOutOfOrder
    case expired
    case rateLimited
}

/// One hint: a rule ID, the extension's confidence (0–100), and the value's keyed digest.
public struct EditorHint: Equatable, Sendable {
    public let rule: String
    public let confidence: Int
    public let digest: Data
}

/// Accepts only a sequence number exactly one more than the last.
public struct HintSequenceGuard: Sendable {
    private var last: Int64 = -1

    public init() {}

    public mutating func accept(_ value: Any?) throws {
        guard let sequence = try? HintProtocol.integer(value), sequence == last + 1 else {
            throw HintProtocolError.replayedOrOutOfOrder
        }
        last = sequence
    }
}

/// Splits a byte stream into length-prefixed frames, refusing oversized lengths before buffering.
public struct HintFrameDecoder: Sendable {
    private var buffered = Data()

    public init() {}

    public mutating func push(_ chunk: Data) throws -> [Data] {
        buffered.append(chunk)
        var frames: [Data] = []
        while buffered.count >= 4 {
            let length = buffered.prefix(4).reduce(0) { $0 << 8 | Int($1) }
            guard length <= HintProtocol.maximumFrameBytes else { throw HintProtocolError.oversizedMessage }
            guard buffered.count >= 4 + length else { break }
            frames.append(Data(buffered.dropFirst(4).prefix(length)))
            buffered = Data(buffered.dropFirst(4 + length))
        }
        return frames
    }

    public static func encode(_ payload: Data) throws -> Data {
        guard payload.count <= HintProtocol.maximumFrameBytes else { throw HintProtocolError.oversizedMessage }
        let length = UInt32(payload.count)
        return Data([UInt8(length >> 24 & 0xFF), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)])
            + payload
    }
}

extension CharacterSet {
    static let base64url = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
}
