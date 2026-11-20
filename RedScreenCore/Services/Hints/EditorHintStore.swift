import Foundation

/// Holds the current session's fresh VS Code hints in memory and matches them to native findings.
///
/// - A hint matches a finding only when the rule IDs are equal and the hint's digest equals the
///   digest RedScreen computes, under the session's digest key, from the finding's own OCR text.
///   RedScreen never receives or asks for the editor's value.
/// - Matching can only confirm a finding (and raise it to `likely`); it never removes or
///   lowers one, and unmatched hints have no effect.
/// - Hints are dropped when they expire, when their connection closes or withdraws them, when a
///   document is opened or closed, after one capture has used them, and when the session ends.
@MainActor
public final class EditorHintStore {
    private struct Key: Hashable {
        let connection: UUID
        let doc: Data
    }

    private struct Entry {
        let hints: [EditorHint]
        let expires: Int64
    }

    private var digestKey: Data?
    private var entries: [Key: Entry] = [:]
    private let now: () -> Int64

    public init(now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.now = now
    }

    public var isSessionActive: Bool { digestKey != nil }

    /// Hints currently held and not yet expired.
    public var liveHintCount: Int {
        let current = now()
        return entries.values.filter { $0.expires > current }.reduce(0) { $0 + $1.hints.count }
    }

    public func beginSession(digestKey: Data) {
        endSession()
        self.digestKey = digestKey
    }

    /// Forgets every hint and the session's digest key.
    public func endSession() {
        entries.removeAll()
        if var key = digestKey { key.resetBytes(in: 0..<key.count) }
        digestKey = nil
    }

    /// Drops every hint but keeps the session, for example after a capture used them.
    public func discardHints() {
        entries.removeAll()
    }

    public func apply(_ event: HintBridgeServer.Event) {
        guard isSessionActive else { return }
        switch event {
        case .hints(let connection, let doc, let expires, let hints):
            entries[Key(connection: connection, doc: doc)] = Entry(hints: hints, expires: expires)
        case .cleared(let connection, let doc):
            entries.removeValue(forKey: Key(connection: connection, doc: doc))
        case .disconnected(let connection):
            entries = entries.filter { $0.key.connection != connection }
        case .authenticated, .rejected:
            break
        }
    }

    /// Confirms findings whose OCR value matches a fresh hint. Returns every finding (confirmed
    /// or unchanged, in the same order) and the number confirmed.
    public func confirm(
        _ detections: [SecretDetection], observations: [OCRObservation]
    ) -> (detections: [SecretDetection], confirmed: Int) {
        let current = now()
        entries = entries.filter { $0.value.expires > current }
        guard let digestKey, !entries.isEmpty else { return (detections, 0) }
        let hints = entries.values.flatMap(\.hints)
        let byID = Dictionary(uniqueKeysWithValues: observations.map { ($0.id, $0) })
        var confirmed = 0
        let result = detections.map { detection -> SecretDetection in
            let rule = detection.evidence.ruleID.rawValue
            let candidates = hints.filter { $0.rule == rule }
            guard !candidates.isEmpty, let value = Self.value(of: detection, in: byID) else { return detection }
            let digest = HintProtocol.digest(digestKey: digestKey, rule: rule, value: value)
            guard let hint = candidates.filter({ $0.digest == digest }).max(by: { $0.confidence < $1.confidence }),
                  let confidence = try? Confidence(Double(hint.confidence) / 100),
                  let updated = try? detection.confirmed(by: EditorHintConfirmation(
                    ruleID: detection.evidence.ruleID, confidence: confidence)) else {
                return detection
            }
            confirmed += 1
            return updated
        }
        return (result, confirmed)
    }

    /// The finding's text as OCR read it: spans on one line are concatenated, and lines are
    /// joined with "\n", which normalization reduces exactly as the extension does.
    nonisolated static func value(of detection: SecretDetection, in observations: [OCRObservation.ID: OCRObservation]) -> String? {
        var lines: [String] = []
        var lastObservation: OCRObservation.ID?
        for span in detection.spans {
            guard let observation = observations[span.observationID] else { return nil }
            let utf16 = Array(observation.text.utf16)
            guard span.utf16Range.lowerBound >= 0, span.utf16Range.upperBound <= utf16.count else { return nil }
            let text = String(decoding: utf16[span.utf16Range], as: UTF16.self)
            if span.observationID == lastObservation, !lines.isEmpty {
                lines[lines.count - 1] += text
            } else {
                lines.append(text)
            }
            lastObservation = span.observationID
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
