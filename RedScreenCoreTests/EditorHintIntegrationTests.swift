import CoreGraphics
import Foundation
import XCTest

@testable import RedScreenCore

/// RED-13: fresh, authenticated hints confirm native findings in a capture, and nothing else.
@MainActor
final class EditorHintIntegrationTests: XCTestCase {
    /// Native: an access key ID alone is `needsReview` (0.6); the password line is `likely`.
    private let lines = ["AKIAIOSFODNN7EXAMPLE", "DATABASE_PASSWORD=RSFAKE-pg-7d1c9a42"]
    private var clock: Int64 = 1_767_225_600_000
    private var store: EditorHintStore!
    private let digestKey = Data(repeating: 0x5A, count: 32)

    override func setUp() async throws {
        store = EditorHintStore { [unowned self] in clock }
        store.beginSession(digestKey: digestKey)
    }

    // MARK: - Matching

    func testMatchingFreshHintRaisesAReviewFindingToLikelyAndMarksIt() async throws {
        let baseline = try await capture(hints: nil)
        let aws = try XCTUnwrap(baseline.first { $0.evidence.first?.ruleID.rawValue == "provider.aws-access-key-id" })
        XCTAssertEqual(aws.assessment, .needsReview)
        XCTAssertEqual(aws.disposition, .pending)

        give([hint("provider.aws-access-key-id", 90, "AKIAIOSFODNN7EXAMPLE")])
        let confirmed = try await capture(hints: store)
        let raised = try XCTUnwrap(confirmed.first { $0.evidence.first?.ruleID.rawValue == "provider.aws-access-key-id" })
        XCTAssertEqual(raised.assessment, .likely)
        XCTAssertEqual(raised.disposition, .included, "Raised findings are redacted by default and still listed for review")
        XCTAssertTrue(raised.isConfirmedByEditorHint)
        XCTAssertEqual(raised.evidence.map(\.ruleID), aws.evidence.map(\.ruleID), "Native provenance is preserved")
        XCTAssertEqual(raised.evidence.map(\.confidence), aws.evidence.map(\.confidence), "Native confidence is kept as recorded")
        XCTAssertEqual(confirmed.count, baseline.count, "Hints never add or remove candidates")
    }

    func testLowConfidenceHintClarifiesWithoutRaising() async throws {
        give([hint("provider.aws-access-key-id", 40, "AKIAIOSFODNN7EXAMPLE")])
        let candidates = try await capture(hints: store)
        let aws = try XCTUnwrap(candidates.first { $0.evidence.first?.ruleID.rawValue == "provider.aws-access-key-id" })
        XCTAssertEqual(aws.assessment, .needsReview)
        XCTAssertEqual(aws.disposition, .pending)
        XCTAssertTrue(aws.isConfirmedByEditorHint)
    }

    func testHintsThatDoNotMatchHaveNoEffect() async throws {
        let baseline = summary(try await capture(hints: nil))
        let cases: [[EditorHint]] = [
            [hint("provider.aws-access-key-id", 99, "AKIAOTHERVALUEEXAMPLE")],  // different value
            [hint("assignment.env", 99, "AKIAIOSFODNN7EXAMPLE")],  // different rule
            [EditorHint(rule: "provider.aws-access-key-id", confidence: 99,
                        digest: HintProtocol.digest(digestKey: Data(repeating: 1, count: 32), rule: "provider.aws-access-key-id",
                                                    value: "AKIAIOSFODNN7EXAMPLE"))],  // another session's key
        ]
        for hints in cases {
            give(hints)
            let result = summary(try await capture(hints: store))
            XCTAssertEqual(result, baseline)
        }
    }

    func testExpiredHintsHaveNoEffect() async throws {
        let baseline = summary(try await capture(hints: nil))
        give([hint("provider.aws-access-key-id", 99, "AKIAIOSFODNN7EXAMPLE")], expiresIn: 1_000)
        clock += 1_001
        let result = summary(try await capture(hints: store))
        XCTAssertEqual(result, baseline)
    }

    func testHintsCannotLowerOrRemoveNativeFindings() async throws {
        let baseline = try await capture(hints: nil)
        give([hint("assignment.env", 0, "RSFAKE-pg-7d1c9a42")])
        let candidates = try await capture(hints: store)
        let password = try XCTUnwrap(candidates.first { $0.evidence.first?.ruleID.rawValue == "assignment.env" })
        XCTAssertEqual(password.assessment, .likely, "A zero-confidence hint does not lower a likely finding")
        XCTAssertEqual(password.disposition, .included)
        XCTAssertEqual(candidates.count, baseline.count)
    }

    // MARK: - Lifetime

    func testHintsAreUsedByOneCaptureOnly() async throws {
        give([hint("provider.aws-access-key-id", 90, "AKIAIOSFODNN7EXAMPLE")])
        let controller = makeController(hints: store)
        let first = try await capture(with: controller)
        XCTAssertTrue(first.contains { $0.isConfirmedByEditorHint })
        XCTAssertEqual(store.liveHintCount, 0, "Capture completion discards the hints")
        let second = try await capture(with: controller)
        XCTAssertFalse(second.contains { $0.isConfirmedByEditorHint })
    }

    func testImportsNeverUseHintsAndDiscardThem() async throws {
        give([hint("provider.aws-access-key-id", 90, "AKIAIOSFODNN7EXAMPLE")])
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("rs-hint-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: work) }
        let fixture = try FixtureLibrary.bundled().fixture(id: "env-file-light-2x")
        try fixture.imageData().write(to: work)
        let controller = makeController(hints: store)
        await controller.importImage(from: work).value
        await controller.currentRecognition?.value
        await controller.currentDetection?.value
        XCTAssertFalse(controller.activeDocument?.candidates.contains { $0.isConfirmedByEditorHint } ?? true)
        XCTAssertEqual(store.liveHintCount, 0)
    }

    func testClosingTheDocumentOrEndingTheSessionForgetsHints() {
        give([hint("provider.aws-access-key-id", 90, "AKIAIOSFODNN7EXAMPLE")])
        let controller = makeController(hints: store)
        controller.closeDocument()
        XCTAssertEqual(store.liveHintCount, 0)

        give([hint("provider.aws-access-key-id", 90, "AKIAIOSFODNN7EXAMPLE")])
        store.endSession()
        XCTAssertEqual(store.liveHintCount, 0)
        XCTAssertFalse(store.isSessionActive)
        store.apply(.hints(connection: UUID(), doc: Data(count: 16), expires: clock + 10_000,
                           hints: [hint("provider.aws-access-key-id", 90, "AKIAIOSFODNN7EXAMPLE")]))
        XCTAssertEqual(store.liveHintCount, 0, "Hints arriving after the session ended are ignored")
    }

    func testDisconnectAndClearWithdrawThatConnectionsHints() {
        let a = UUID(), b = UUID()
        store.apply(.hints(connection: a, doc: Data(count: 16), expires: clock + 10_000, hints: [hint("bearer.token", 90, "x")]))
        store.apply(.hints(connection: b, doc: Data(count: 16), expires: clock + 10_000, hints: [hint("bearer.token", 90, "y")]))
        store.apply(.hints(connection: b, doc: Data(repeating: 1, count: 16), expires: clock + 10_000, hints: [hint("bearer.token", 90, "z")]))
        XCTAssertEqual(store.liveHintCount, 3)
        store.apply(.cleared(connection: b, doc: Data(repeating: 1, count: 16)))
        XCTAssertEqual(store.liveHintCount, 2)
        store.apply(.disconnected(connection: a))
        XCTAssertEqual(store.liveHintCount, 1)
    }

    // MARK: - Regression and safeguards

    /// With the bridge off, detection is exactly the native result.
    func testWithoutHintsTheWorkflowIsUnchanged() async throws {
        let native = summary(try await capture(hints: nil))
        store.endSession()
        let ended = summary(try await capture(hints: store))
        XCTAssertEqual(ended, native)
        let idle = summary(try await capture(hints: EditorHintStore()))
        XCTAssertEqual(idle, native)
    }

    /// Hints never authorize export: an unresolved finding still blocks rendering.
    func testHintsDoNotBypassTheUnresolvedCandidateGate() async throws {
        give([hint("provider.aws-access-key-id", 40, "AKIAIOSFODNN7EXAMPLE")])
        let controller = makeController(hints: store)
        _ = try await capture(with: controller)
        XCTAssertGreaterThan(controller.pendingReviewCount, 0)
        XCTAssertFalse(controller.canRenderReviewedImage)
    }

    // MARK: - Bridge end to end, with privacy checks

    func testBridgeDeliversAuthenticatedHintsAndLeavesNothingBehind() async throws {
        let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("rsh-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sink = Sink()
        let bridgeStore = EditorHintStore()
        let bridge = EditorHintBridge(configuration: .init(directory: directory), store: bridgeStore,
                                      logger: PrivacySafeLogger(sink: sink))
        XCTAssertEqual(bridge.status, .off)
        bridge.start()
        XCTAssertEqual(bridge.status, .waiting)

        let client = try HintTestClient(pairing: HintTestClient.pairing(at: bridge.pairingURL))
        try client.handshake()
        try client.sendHints(doc: Data(repeating: 8, count: 16), hints: [("provider.aws-access-key-id", 90, "AKIAIOSFODNN7EXAMPLE")])
        try await waitUntil { bridgeStore.liveHintCount == 1 && bridge.status == .connected(1) }

        let candidates = try await capture(with: makeController(hints: bridgeStore, logger: PrivacySafeLogger(sink: sink)))
        XCTAssertTrue(candidates.contains { $0.isConfirmedByEditorHint })

        client.close()
        try await waitUntil { bridge.status == .waiting }
        bridge.stop()
        XCTAssertEqual(bridge.status, .off)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [],
                       "Stopping removes the pairing file and socket")
        XCTAssertFalse(bridgeStore.isSessionActive)

        // Logs are fixed events with counts: no digests, values, or document identifiers.
        let events = sink.entries.map(\.event)
        for expected in [PrivacyLogEvent.hintBridgeStarted, .hintPeerAuthenticated, .editorHintsConfirmed, .hintBridgeStopped] {
            XCTAssertTrue(events.contains(expected), "\(expected)")
        }
        XCTAssertEqual(sink.entries.first { $0.event == .editorHintsConfirmed }?.count, 1)
        XCTAssertTrue(sink.entries.allSatisfy { $0.count < 1_000_000_000 }, "Counts only")
    }

    // MARK: - Helpers

    private func hint(_ rule: String, _ confidence: Int, _ value: String) -> EditorHint {
        EditorHint(rule: rule, confidence: confidence, digest: HintProtocol.digest(digestKey: digestKey, rule: rule, value: value))
    }

    private func give(_ hints: [EditorHint], expiresIn: Int64 = 20_000) {
        store.apply(.hints(connection: UUID(), doc: HintBridgeServer.randomBytes(16), expires: clock + expiresIn, hints: hints))
    }

    private func makeController(hints: EditorHintStore?, logger: PrivacySafeLogger = PrivacySafeLogger(sink: Sink())) -> ScreenshotImportController {
        ScreenshotImportController(
            lifecycle: SecureImageSessionLifecycle(),
            importer: ImageIOImageImporter(),
            screenCapturer: SolidCapturer(),
            editorHints: hints,
            textRecognizer: LinesRecognizer(lines: lines),
            secretDetector: ContextualSecretDetector(),
            candidateComposer: GeometricCandidateComposer(),
            logger: logger
        )
    }

    private func capture(hints: EditorHintStore?) async throws -> [RedactionCandidate] {
        try await capture(with: makeController(hints: hints))
    }

    private func capture(with controller: ScreenshotImportController) async throws -> [RedactionCandidate] {
        await controller.captureScreenshot(.display(id: 1))?.value
        await controller.currentRecognition?.value
        await controller.currentDetection?.value
        XCTAssertEqual(controller.workflowState, .reviewing)
        return try XCTUnwrap(controller.activeDocument?.candidates)
    }

    private func summary(_ candidates: [RedactionCandidate]) -> [String] {
        candidates.map { "\($0.evidence.map(\.ruleID.rawValue)) \(String(describing: $0.assessment)) \($0.disposition) \($0.editorHints.count)" }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }
}

private struct SolidCapturer: ScreenCaptureService {
    func capture(_ target: CaptureTarget) async throws -> ImportedImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 400, height: 120, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 120))
        return try CapturedImageNormalizer.normalize(XCTUnwrap(context.makeImage()), treatsTransparentAsProtected: false)
    }
}

/// Returns fixed synthetic lines as OCR output.
private struct LinesRecognizer: TextRecognizer {
    let lines: [String]

    func recognizeText(in pixels: DecodedPixels, dimensions: PixelDimensions) async throws -> [OCRObservation] {
        try lines.enumerated().map { index, line in
            try OCRObservation(text: line, boundingBox: NormalizedRect(x: 0.05, y: 0.1 + Double(index) * 0.3, width: 0.9, height: 0.2),
                               boundingBoxOrigin: .topLeft, confidence: Confidence(0.95))
        }
    }
}

private final class Sink: PrivacyLogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [PrivacyLogEntry] = []
    var entries: [PrivacyLogEntry] { lock.withLock { stored } }
    func write(_ entry: PrivacyLogEntry) { lock.withLock { stored.append(entry) } }
}
