import Foundation
import OSLog

/// The complete set of production log events.
///
/// Keeping identifiers closed prevents raw OCR text, detected values, filenames, file URLs, and
/// other caller-provided strings from becoming production log payloads.
public enum PrivacyLogEvent: String, CaseIterable, Equatable, Sendable {
    case sessionCreated = "session_created"
    case sessionReplaced = "session_replaced"
    case sessionReset = "session_reset"
    case pixelsDecoded = "pixels_decoded"
    case textRecognized = "text_recognized"
    case sensitiveInformationDetected = "sensitive_information_detected"
    case previewUpdated = "preview_updated"
    case clipboardPrepared = "clipboard_prepared"
    case undoStateUpdated = "undo_state_updated"
}

/// The only payload accepted by the privacy-safe logging boundary.
public struct PrivacyLogEntry: Equatable, Sendable {
    public let event: PrivacyLogEvent
    public let count: UInt

    public init(event: PrivacyLogEvent, count: UInt = 0) {
        self.event = event
        self.count = count
    }
}

public protocol PrivacyLogSink: Sendable {
    func write(_ entry: PrivacyLogEntry)
}

/// Production logger whose API cannot accept arbitrary strings.
public struct PrivacySafeLogger: Sendable {
    private let sink: any PrivacyLogSink

    public init(sink: any PrivacyLogSink = OSPrivacyLogSink()) {
        self.sink = sink
    }

    public func record(_ event: PrivacyLogEvent, count: UInt = 0) {
        sink.write(PrivacyLogEntry(event: event, count: count))
    }
}

/// Unified logging adapter. Every message is a static format string selected by a closed enum.
public struct OSPrivacyLogSink: PrivacyLogSink {
    private let logger = Logger(subsystem: "com.georgeadadii.RedScreen", category: "privacy-events")

    public init() {}

    public func write(_ entry: PrivacyLogEntry) {
        switch entry.event {
        case .sessionCreated:
            logger.info("session_created count=\(entry.count)")
        case .sessionReplaced:
            logger.info("session_replaced count=\(entry.count)")
        case .sessionReset:
            logger.info("session_reset count=\(entry.count)")
        case .pixelsDecoded:
            logger.info("pixels_decoded count=\(entry.count)")
        case .textRecognized:
            logger.info("text_recognized count=\(entry.count)")
        case .sensitiveInformationDetected:
            logger.info("sensitive_information_detected count=\(entry.count)")
        case .previewUpdated:
            logger.info("preview_updated count=\(entry.count)")
        case .clipboardPrepared:
            logger.info("clipboard_prepared count=\(entry.count)")
        case .undoStateUpdated:
            logger.info("undo_state_updated count=\(entry.count)")
        }
    }
}
