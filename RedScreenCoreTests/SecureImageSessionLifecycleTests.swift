import Foundation
import XCTest

@testable import RedScreenCore

@MainActor
final class SecureImageSessionLifecycleTests: XCTestCase {
    func testSessionCreationReplacementAndReset() {
        let lifecycle = SecureImageSessionLifecycle(logger: silentLogger)
        let first = lifecycle.createSession(sourceImage: ScreenshotImage(data: Data([0x01])))

        XCTAssertTrue(lifecycle.activeSession === first)
        XCTAssertEqual(first.sourceImage?.data, Data([0x01]))

        XCTAssertTrue(lifecycle.storeDecodedPixels(DecodedPixels(bytes: Data([0x02])), for: first.id))
        XCTAssertTrue(lifecycle.storeRecognizedText([RecognizedText(value: "private OCR")], for: first.id))
        XCTAssertTrue(lifecycle.storeDetectedInformation([
            DetectedSensitiveInformation(region: SensitiveRegion(), candidateValue: "secret")
        ], for: first.id))
        XCTAssertTrue(lifecycle.storePreview(ScreenshotImage(data: Data([0x03])), for: first.id))
        XCTAssertTrue(lifecycle.storeClipboardImage(ScreenshotImage(data: Data([0x04])), for: first.id))
        XCTAssertTrue(lifecycle.appendUndoState(RedactionUndoState(redactedRegions: [SensitiveRegion()]), for: first.id))

        let replacement = lifecycle.createSession(sourceImage: ScreenshotImage(data: Data([0x05])))

        XCTAssertTrue(lifecycle.activeSession === replacement)
        XCTAssertNil(first.sourceImage)
        XCTAssertNil(first.decodedPixels)
        XCTAssertTrue(first.recognizedText.isEmpty)
        XCTAssertTrue(first.detectedInformation.isEmpty)
        XCTAssertNil(first.previewImage)
        XCTAssertNil(first.clipboardImage)
        XCTAssertTrue(first.undoHistory.isEmpty)
        XCTAssertFalse(lifecycle.storeRecognizedText([RecognizedText(value: "stale")], for: first.id))

        lifecycle.reset()

        XCTAssertNil(lifecycle.activeSession)
        XCTAssertNil(replacement.sourceImage)
    }

    func testResetReleasesLifecycleReferenceToSession() {
        let lifecycle = SecureImageSessionLifecycle(logger: silentLogger)
        var session: SecureImageSession? = lifecycle.createSession(
            sourceImage: ScreenshotImage(data: Data(repeating: 0xAB, count: 32))
        )
        weak var weakSession = session

        lifecycle.reset()
        session = nil

        XCTAssertNil(weakSession)
    }

    func testReplacementReleasesLifecycleReferenceToPreviousSession() {
        let lifecycle = SecureImageSessionLifecycle(logger: silentLogger)
        var firstSession: SecureImageSession? = lifecycle.createSession(
            sourceImage: ScreenshotImage(data: Data([0x01]))
        )
        weak var weakFirstSession = firstSession
        firstSession = nil

        lifecycle.createSession(sourceImage: ScreenshotImage(data: Data([0x02])))

        XCTAssertNil(weakFirstSession)
    }

    func testPrivacyLoggerContainsOnlyIdentifiersAndCounts() {
        let sink = RecordingPrivacyLogSink()
        let lifecycle = SecureImageSessionLifecycle(logger: PrivacySafeLogger(sink: sink))
        let rawOCR = "AKIA-RAW-OCR-SHOULD-NOT-APPEAR"
        let detectedSecret = "password=hunter2"
        let sensitiveFilename = "/Users/person/Top Secret Screenshot.png"
        let session = lifecycle.createSession(sourceImage: ScreenshotImage(data: Data([0x01])))

        lifecycle.storeRecognizedText([RecognizedText(value: rawOCR)], for: session.id)
        lifecycle.storeDetectedInformation([
            DetectedSensitiveInformation(region: SensitiveRegion(), candidateValue: detectedSecret)
        ], for: session.id)
        lifecycle.reset()

        let serializedEntries = sink.entries
            .map { "\($0.event.rawValue):\($0.count)" }
            .joined(separator: "\n")

        XCTAssertEqual(sink.entries.map(\.event), [
            .sessionCreated,
            .textRecognized,
            .sensitiveInformationDetected,
            .sessionReset
        ])
        XCTAssertFalse(serializedEntries.contains(rawOCR))
        XCTAssertFalse(serializedEntries.contains(detectedSecret))
        XCTAssertFalse(serializedEntries.contains(sensitiveFilename))
    }

    func testLifecycleCreatesNoApplicationManagedPlaintextTemporaryImage() throws {
        let isolatedTemporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RedScreenLifecycleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: isolatedTemporaryDirectory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: isolatedTemporaryDirectory) }

        let lifecycle = SecureImageSessionLifecycle(logger: silentLogger)
        let sourceBytes = Data("plaintext-source-image".utf8)
        let session = lifecycle.createSession(sourceImage: ScreenshotImage(data: sourceBytes))
        lifecycle.storeDecodedPixels(DecodedPixels(bytes: sourceBytes), for: session.id)
        lifecycle.storePreview(ScreenshotImage(data: sourceBytes), for: session.id)
        lifecycle.reset()

        let files = try FileManager.default.contentsOfDirectory(
            at: isolatedTemporaryDirectory,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(files.isEmpty)
        XCTAssertFalse(ImageLifecyclePolicy.usesApplicationManagedPlaintextTemporaryImages)
    }

    func testPrivacyPoliciesProhibitImplicitPersistenceAndNetworking() {
        XCTAssertTrue(ImageLifecyclePolicy.processingIsOnDeviceOnly)
        XCTAssertFalse(ImageLifecyclePolicy.automaticallyPersistsSourceImages)
        XCTAssertFalse(ImageLifecyclePolicy.automaticallyPersistsRecognizedText)
        XCTAssertFalse(ImageLifecyclePolicy.automaticallyPersistsDetectedInformation)
        XCTAssertFalse(ImageLifecyclePolicy.registersRecentDocuments)
        XCTAssertFalse(ImageLifecyclePolicy.permitsNetworkAccess)
    }

    private var silentLogger: PrivacySafeLogger {
        PrivacySafeLogger(sink: RecordingPrivacyLogSink())
    }
}

private final class RecordingPrivacyLogSink: PrivacyLogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var storedEntries: [PrivacyLogEntry] = []

    var entries: [PrivacyLogEntry] {
        lock.withLock { storedEntries }
    }

    func write(_ entry: PrivacyLogEntry) {
        lock.withLock {
            storedEntries.append(entry)
        }
    }
}
