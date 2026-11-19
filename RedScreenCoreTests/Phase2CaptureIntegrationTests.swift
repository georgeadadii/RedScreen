import AppKit
import Foundation
import ImageIO
import XCTest

@testable import RedScreenCore

/// RED-11: captured frames go through the same production pipeline as imports. The frames are
/// injected, so these tests capture nothing from the real screen. Reports print fixture IDs,
/// counts, durations, and memory figures only.
@MainActor
final class Phase2CaptureIntegrationTests: XCTestCase {
    private var work: URL!

    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory
            .appendingPathComponent("RedScreenPhase2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        if let work { try? FileManager.default.removeItem(at: work) }
    }

    // MARK: - End to end

    func testRegionWindowAndDisplayCapturesCompleteRedactionSaveAndCopy() async throws {
        let fixture = try FixtureLibrary.bundled().fixture(id: "env-file-light-2x")
        let truth = fixture.groundTruth
        let frame = try Frames.image(fromEncoded: fixture.imageData())
        let dimensions = try truth.pixelDimensions()
        let sensitive = truth.spans.filter { $0.expectation == .sensitive }
        XCTAssertFalse(sensitive.isEmpty)

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("RedScreenPhase2-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let watched = FileInventory.watchedDirectories(excluding: work)
        let before = FileInventory.snapshot(watched)
        let startedAt = Date()
        let sink = EntrySink()
        let lifecycle = SecureImageSessionLifecycle(logger: PrivacySafeLogger(sink: sink))
        let capturer = FrameCapturer { _, _ in try CapturedImageNormalizer.normalize(frame, treatsTransparentAsProtected: false) }
        let controller = ScreenshotImportController(
            lifecycle: lifecycle,
            importer: ImageIOImageImporter(),
            screenCapturer: capturer,
            textRecognizer: VisionTextRecognizer(),
            secretDetector: ContextualSecretDetector(),
            candidateComposer: GeometricCandidateComposer(),
            imageExporter: AtomicFileImageExporter(),
            clipboard: PasteboardImageWriter(pasteboard: pasteboard),
            logger: PrivacySafeLogger(sink: sink)
        )

        let targets: [CaptureTarget] = [
            .region(CGRect(x: 10, y: 20, width: 600, height: 400)), .window(id: 42), .display(id: 1),
        ]
        weak var previousSession: SecureImageSession?
        for (index, target) in targets.enumerated() {
            await controller.captureScreenshot(target)?.value
            await controller.currentRecognition?.value
            await controller.currentDetection?.value
            XCTAssertEqual(controller.workflowState, .reviewing, "\(target)")
            XCTAssertEqual(controller.document?.pixelDimensions, dimensions)
            XCTAssertNil(previousSession?.decodedPixels, "The replaced capture's pixels must be cleared")
            previousSession = lifecycle.activeSession

            let source = try XCTUnwrap(controller.activePixels)
            let candidates = try XCTUnwrap(controller.activeDocument?.candidates)
            XCTAssertGreaterThanOrEqual(candidates.count, sensitive.count, "\(target): each secret is found")
            for candidate in candidates where candidate.disposition == .pending {
                XCTAssertTrue(controller.setReviewDisposition(.included, for: candidate.id))
            }
            let rendered = try await controller.renderReviewedImage()
            let destination = work.appendingPathComponent("redacted-\(index).png")
            try await controller.exportReviewedImage(rendered, to: ExportDestination(url: destination))
            try controller.copyReviewedImage(rendered)

            let saved = try Data(contentsOf: destination)
            XCTAssertEqual(pasteboard.data(forType: .png), saved, "Saved and copied output are identical")
            let output = try Frames.decode(saved)
            XCTAssertEqual(output, rendered.pixels.bytes, "The saved file is exactly the reviewed render")
            let flattened = DecodedPixels(bytes: output, layout: source.layout)
            var secretInk = 0
            for span in sensitive {
                for segment in span.segments {
                    let rect = try segment.rect.imageRect(in: dimensions).enclosingPixelRect(in: dimensions)
                    let background = Frames.dominantColor(in: rect, pixels: source)
                    for y in rect.y..<(rect.y + rect.height) {
                        for x in rect.x..<(rect.x + rect.width) where Frames.isInk(source.pixel(x: x, y: y), background) {
                            secretInk += 1
                            XCTAssertEqual(flattened.pixel(x: x, y: y), .init(red: 0, green: 0, blue: 0, alpha: 255),
                                           "\(target): \(span.id) ink survives")
                        }
                    }
                }
            }
            XCTAssertGreaterThan(secretInk, 0)
        }
        XCTAssertEqual(capturer.targets, targets, "Each capture asked for exactly its target")

        // Only the chosen destinations exist; nothing else the run wrote is an image or text.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path).sorted(),
                       ["redacted-0.png", "redacted-1.png", "redacted-2.png"])
        let secretValues = sensitive.compactMap { truth.text(of: $0) }.filter { $0.count >= 8 }
        let workPath = work.resolvingSymlinksInPath().path + "/"
        for file in FileInventory.snapshot(watched).subtracting(before)
        where !file.resolvingSymlinksInPath().path.hasPrefix(workPath) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                  let modified = attributes[.modificationDate] as? Date, modified >= startedAt,
                  let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { continue }
            XCTAssertFalse(FileInventory.isImage(data), "Image written outside a destination: \(file.lastPathComponent)")
            let text = String(decoding: data, as: UTF8.self)
            XCTAssertFalse(secretValues.contains { text.contains($0) }, "Secret text written to \(file.lastPathComponent)")
        }

        // Logs: closed events with numeric counts. Each capture is timed to review exactly once.
        let events = sink.entries.map(\.event)
        XCTAssertEqual(events.filter { $0 == .screenCaptured }.count, 3)
        XCTAssertEqual(events.filter { $0 == .captureToReviewDuration }.count, 3)
        XCTAssertEqual(events.filter { $0 == .memoryFootprint }.count, 3)
        XCTAssertEqual(events.filter { $0 == .sessionCreated }.count, 1)
        XCTAssertEqual(events.filter { $0 == .sessionReplaced }.count, 2)
        XCTAssertEqual(events.filter { $0 == .redactedImageSaved }.count, 3)
        XCTAssertFalse(events.contains(.imageImported), "Captures are not logged as imports")
        XCTAssertTrue(sink.entries.filter { $0.event == .memoryFootprint }.allSatisfy { $0.count > 0 })

        controller.closeDocument()
        XCTAssertEqual(controller.workflowState, .idle)
        XCTAssertNil(lifecycle.activeSession)
        XCTAssertNil(previousSession, "The last session is released after close")
    }

    // MARK: - Stress

    /// Rapid shortcut use: many captures started back to back, finishing out of order and
    /// ignoring cancellation, as a slow capture service might. Only the newest one opens.
    func testRapidRepeatedCapturesOpenOnlyTheNewestFrame() async throws {
        let count = 25
        let sink = EntrySink()
        let lifecycle = SecureImageSessionLifecycle(logger: PrivacySafeLogger(sink: sink))
        // Each request is identified by its region's x; tasks may reach the service in any order.
        let capturer = FrameCapturer(honorsCancellation: false, delay: { .milliseconds((count - $0) * 3) }) { target, _ in
            guard case .region(let rect) = target else { throw CaptureError.failed }
            return try Frames.solid(gray: UInt8(Int(rect.minX) * 9), width: 64, height: 40)
        }
        let controller = ScreenshotImportController(
            lifecycle: lifecycle, importer: ImageIOImageImporter(), screenCapturer: capturer,
            logger: PrivacySafeLogger(sink: sink)
        )

        var tasks: [Task<Void, Never>] = []
        for index in 0..<count {
            tasks.append(try XCTUnwrap(controller.captureScreenshot(.region(CGRect(x: index, y: 0, width: 64, height: 40)))))
        }
        for task in tasks { await task.value }

        XCTAssertEqual(capturer.callCount, count)
        let pixels = try XCTUnwrap(controller.activePixels)
        XCTAssertEqual(pixels.pixel(x: 0, y: 0).red, UInt8((count - 1) * 9), "The newest capture must win")
        XCTAssertEqual(controller.document?.sessionID, lifecycle.activeSession?.id)
        XCTAssertFalse(controller.isImporting)
        let events = sink.entries.map(\.event)
        XCTAssertEqual(events.filter { $0 == .sessionCreated }.count, 1, "Stale results create no session")
        XCTAssertFalse(events.contains(.sessionReplaced))
        XCTAssertEqual(events.filter { $0 == .screenCaptured }.count, 1)
        XCTAssertNil(controller.lastCaptureError)
    }

    /// Captures, imports, cancellations, failures, and closes interleaved in a fixed pseudo-random
    /// order. No session survives its replacement, and the controller always ends consistent.
    func testInterleavedCaptureImportCancelAndCloseNeverLeakEarlierSessions() async throws {
        let fixture = try FixtureLibrary.bundled().fixture(id: "env-file-light-2x")
        let input = work.appendingPathComponent("input.png")
        try fixture.imageData().write(to: input)
        let lifecycle = SecureImageSessionLifecycle()
        let capturer = FrameCapturer(delay: { .milliseconds($0 % 4) }) { target, index in
            if case .window = target, index % 5 == 0 { throw CaptureError.targetUnavailable }
            return try Frames.solid(gray: UInt8(truncatingIfNeeded: index), width: 48, height: 32)
        }
        let controller = ScreenshotImportController(lifecycle: lifecycle, importer: ImageIOImageImporter(),
                                                    screenCapturer: capturer)

        var generator = SplitMix(seed: 0x5245_4431_31)
        var seen: [WeakSession] = []
        for step in 0..<120 {
            switch generator.next() % 6 {
            case 0: await controller.captureScreenshot(.display(id: 1))?.value
            case 1: await controller.captureScreenshot(.window(id: UInt32(step)))?.value
            case 2:
                // Superseded before it finishes.
                _ = controller.captureScreenshot(.region(CGRect(x: 0, y: 0, width: 10, height: 10)))
                controller.cancelProcessing()
            case 3: await controller.importImage(from: input).value
            case 4:
                _ = controller.captureScreenshot(.display(id: 2))
                await controller.importImage(from: input).value
            default: controller.closeDocument()
            }
            if let active = lifecycle.activeSession { seen.append(WeakSession(active)) }
            XCTAssertEqual(controller.document?.sessionID, lifecycle.activeSession?.id, "step \(step)")
            for earlier in seen where earlier.session !== lifecycle.activeSession {
                XCTAssertNil(earlier.session?.decodedPixels, "step \(step): an earlier session kept pixels")
            }
        }
        controller.closeDocument()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(lifecycle.activeSession)
        XCTAssertTrue(seen.allSatisfy { $0.session == nil }, "Every session is released after close")
        XCTAssertGreaterThan(Set(seen.compactMap { $0.id }).count, 10, "The run exercised many sessions")
    }

    /// Repeated large captures do not accumulate memory: each replaced frame is released.
    /// Every capture produces a freshly allocated 4K frame, as ScreenCaptureKit does.
    func testRepeatedLargeCapturesReleaseMemory() async throws {
        let width = 3840, height = 2160  // A 4K display frame, about 32 MiB as RGBA.
        let frameMiB = Double(width * height * 4) / 1_048_576
        let lifecycle = SecureImageSessionLifecycle()
        let capturer = FrameCapturer { _, index in
            try Frames.solid(gray: UInt8(truncatingIfNeeded: index), width: width, height: height)
        }
        let controller = ScreenshotImportController(lifecycle: lifecycle, importer: ImageIOImageImporter(),
                                                    screenCapturer: capturer)
        let mib = { (bytes: UInt64) in Double(bytes) / 1_048_576 }

        await controller.captureScreenshot(.display(id: 1))?.value
        controller.closeDocument()
        let baseline = ProcessMemory.footprintBytes()
        var peak = baseline
        for _ in 0..<20 {
            await controller.captureScreenshot(.display(id: 1))?.value
            peak = max(peak, ProcessMemory.footprintBytes())
        }
        controller.closeDocument()
        let after = ProcessMemory.footprintBytes()

        // Control: the same measurement must notice frames that are kept.
        var retained: [ImportedImage] = []
        for index in 0..<8 { retained.append(try Frames.solid(gray: UInt8(index), width: width, height: height)) }
        let retainedGrowth = mib(ProcessMemory.footprintBytes()) - mib(after)
        retained.removeAll()

        print(String(format: "Phase 2 memory 20x4K captures: baseline=%.0fMiB peak=%.0fMiB afterClose=%.0fMiB "
                     + "(8 retained frames: +%.0fMiB)", mib(baseline), mib(peak), mib(after), retainedGrowth))
        XCTAssertGreaterThan(baseline, 0)
        XCTAssertGreaterThan(retainedGrowth, frameMiB * 4, "The footprint measurement must detect retained frames")
        // Twenty retained frames would be about 630 MiB; at most a few frames are live at once.
        XCTAssertLessThan(mib(peak) - mib(baseline), frameMiB * 5, "Replaced frames must be released")
        XCTAssertLessThan(mib(after) - mib(baseline), frameMiB * 3)
    }

    // MARK: - Performance

    /// Capture-to-review latency with the production OCR, detection, and composition on the
    /// smallest and largest corpus screenshots. Baselines are recorded in docs/PHASE2_READINESS.md;
    /// the ceilings are loose tripwires for shared CI machines.
    func testCaptureToReviewLatencyBaselines() async throws {
        let fixtures = try FixtureLibrary.bundled().fixtures()
        let byArea = try fixtures.sorted {
            let a = try $0.decodedPixelSize(), b = try $1.decodedPixelSize()
            return a.width * a.height < b.width * b.height
        }
        for fixture in [byArea.first!, byArea.last!] {
            let frame = try Frames.image(fromEncoded: fixture.imageData())
            let sink = EntrySink()
            let controller = ScreenshotImportController(
                lifecycle: SecureImageSessionLifecycle(), importer: ImageIOImageImporter(),
                screenCapturer: FrameCapturer { _, _ in
                    try CapturedImageNormalizer.normalize(frame, treatsTransparentAsProtected: false)
                },
                textRecognizer: VisionTextRecognizer(), secretDetector: ContextualSecretDetector(),
                candidateComposer: GeometricCandidateComposer(), logger: PrivacySafeLogger(sink: sink)
            )
            let clock = ContinuousClock()
            let start = clock.now
            await controller.captureScreenshot(.display(id: 1))?.value
            let captured = clock.now - start
            await controller.currentRecognition?.value
            await controller.currentDetection?.value
            let reviewable = clock.now - start
            XCTAssertEqual(controller.workflowState, .reviewing)

            let logged = try XCTUnwrap(sink.entries.first { $0.event == .captureToReviewDuration }?.count)
            let memory = try XCTUnwrap(sink.entries.first { $0.event == .memoryFootprint }?.count)
            let size = try fixture.decodedPixelSize()
            print(String(format: "Phase 2 timing %@ %dx%d: capture=%.1fms toReview=%.1fms logged=%dms footprint=%dMiB",
                         fixture.id, size.width, size.height, Frames.ms(captured), Frames.ms(reviewable),
                         Int(logged), Int(memory)))
            XCTAssertLessThanOrEqual(Double(logged), Frames.ms(reviewable) + 5, "The logged figure matches")
            XCTAssertLessThan(Frames.ms(captured), 2_000)
            XCTAssertLessThan(Frames.ms(reviewable), 25_000)
            controller.closeDocument()
        }
    }

    // MARK: - Audit

    /// Capture holds no stream open, the overlay and windows keep screen content out of the
    /// system's records, and nothing registers recent items or restorable state.
    func testCaptureAndLifecycleConfigurationAudit() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func source(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        let service = try source("RedScreen/Capture/ScreenCaptureKitService.swift")
        XCTAssertTrue(service.contains("SCScreenshotManager.captureImage"))
        for stream in ["SCStream(", "startCapture", "addStreamOutput", "SCRecordingOutput"] {
            XCTAssertFalse(service.contains(stream), "No capture stream may be held open: \(stream)")
        }
        XCTAssertTrue(service.contains("showsCursor = false"))
        XCTAssertTrue(service.contains("excludingApplications: ownApplications"))

        let overlay = try source("RedScreen/Capture/RegionSelectionOverlay.swift")
        XCTAssertTrue(overlay.contains("sharingType = .none"))
        for name in ["didResignActiveNotification", "screensDidSleepNotification",
                     "sessionDidResignActiveNotification", "didChangeScreenParametersNotification"] {
            XCTAssertTrue(overlay.contains(name), "The selection must end on \(name)")
        }

        let window = try source("RedScreen/UI/DocumentWindowController.swift")
        XCTAssertTrue(window.contains("isRestorable = false"), "No screenshot-bearing window state is saved")
        let model = try source("RedScreen/App/AppModel.swift")
        XCTAssertTrue(model.contains("willTerminateNotification"), "Quitting clears the open session")

        // No usage strings or entitlements beyond what capture and user-selected files need.
        let project = try source("RedScreen.xcodeproj/project.pbxproj")
        XCTAssertFalse(project.contains("UsageDescription"), "No extra permission prompts are declared")
        XCTAssertFalse(project.contains("com.apple.security.network"))
        XCTAssertFalse(project.contains("NSSupportsAutomaticTermination = NO"))

        // Every log event, including the Phase 2 measurements, is a fixed identifier.
        for event in PrivacyLogEvent.allCases {
            XCTAssertNotNil(event.rawValue.range(of: "^[a-z_]+$", options: .regularExpression), event.rawValue)
        }
        XCTAssertEqual(PrivacyLogEvent.captureToReviewDuration.rawValue, "capture_to_review_duration_ms")
        XCTAssertEqual(PrivacyLogEvent.memoryFootprint.rawValue, "memory_footprint_mb")
    }

    /// Phase 1 is unchanged: an import logs no capture events and keeps its own log sequence.
    func testImportLogsNoCaptureMeasurements() async throws {
        let fixture = try FixtureLibrary.bundled().fixture(id: "env-file-light-2x")
        let input = work.appendingPathComponent("input.png")
        try fixture.imageData().write(to: input)
        let sink = EntrySink()
        let controller = ScreenshotImportController(
            lifecycle: SecureImageSessionLifecycle(), importer: ImageIOImageImporter(),
            textRecognizer: VisionTextRecognizer(), secretDetector: ContextualSecretDetector(),
            candidateComposer: GeometricCandidateComposer(), logger: PrivacySafeLogger(sink: sink)
        )
        await controller.importImage(from: input).value
        await controller.currentRecognition?.value
        await controller.currentDetection?.value
        XCTAssertEqual(controller.workflowState, .reviewing)
        let events = sink.entries.map(\.event)
        XCTAssertTrue(events.contains(.imageImported))
        for capture in [PrivacyLogEvent.screenCaptured, .captureToReviewDuration, .memoryFootprint, .captureFailed] {
            XCTAssertFalse(events.contains(capture), "\(capture) logged for an import")
        }
    }
}

// MARK: - Support

@MainActor
private final class WeakSession {
    weak var session: SecureImageSession?
    let id: UUID?
    init(_ session: SecureImageSession) {
        self.session = session
        id = session.id
    }
}

/// Injected capture: returns frames from a closure after an optional delay. With
/// `honorsCancellation` false it finishes even when its task is canceled, so stale results
/// reach the controller.
private final class FrameCapturer: ScreenCaptureService, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [CaptureTarget] = []
    private let honorsCancellation: Bool
    private let delay: @Sendable (Int) -> Duration
    private let frame: @Sendable (CaptureTarget, Int) throws -> ImportedImage

    init(
        honorsCancellation: Bool = true,
        delay: @escaping @Sendable (Int) -> Duration = { _ in .zero },
        frame: @escaping @Sendable (CaptureTarget, Int) throws -> ImportedImage
    ) {
        self.honorsCancellation = honorsCancellation
        self.delay = delay
        self.frame = frame
    }

    var targets: [CaptureTarget] { lock.withLock { recorded } }
    var callCount: Int { lock.withLock { recorded.count } }

    func capture(_ target: CaptureTarget) async throws -> ImportedImage {
        let index = lock.withLock {
            recorded.append(target)
            return recorded.count - 1
        }
        let wait = delay(index)
        if wait > .zero {
            if honorsCancellation {
                try await Task.sleep(for: wait)
            } else {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(Int(Frames.ms(wait)))) {
                        continuation.resume()
                    }
                }
            }
        }
        if honorsCancellation { try Task.checkCancellation() }
        return try frame(target, index)
    }
}

private final class EntrySink: PrivacyLogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [PrivacyLogEntry] = []
    var entries: [PrivacyLogEntry] { lock.withLock { stored } }
    func write(_ entry: PrivacyLogEntry) { lock.withLock { stored.append(entry) } }
}

/// Deterministic pseudo-random sequence for reproducible stress orderings.
private struct SplitMix {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private enum Frames {
    static func image(fromEncoded data: Data) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    static func solid(gray: UInt8, width: Int, height: Int) throws -> ImportedImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let value = CGFloat(gray) / 255
        context.setFillColor(red: value, green: value, blue: value, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try CapturedImageNormalizer.normalize(XCTUnwrap(context.makeImage()), treatsTransparentAsProtected: false)
    }

    static func decode(_ data: Data) throws -> Data {
        let image = try self.image(fromEncoded: data)
        var bytes = Data(count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    static func dominantColor(in rect: PixelRect, pixels: DecodedPixels) -> TestImageFactory.RGBA {
        var counts: [UInt32: Int] = [:]
        for y in rect.y..<(rect.y + rect.height) {
            for x in stride(from: rect.x, to: rect.x + rect.width, by: 2) {
                let p = pixels.pixel(x: x, y: y)
                counts[UInt32(p.red) << 16 | UInt32(p.green) << 8 | UInt32(p.blue), default: 0] += 1
            }
        }
        let key = counts.max { $0.value < $1.value }?.key ?? 0
        return .init(red: UInt8(key >> 16 & 0xFF), green: UInt8(key >> 8 & 0xFF), blue: UInt8(key & 0xFF), alpha: 255)
    }

    static func isInk(_ pixel: TestImageFactory.RGBA, _ background: TestImageFactory.RGBA) -> Bool {
        abs(Int(pixel.red) - Int(background.red)) + abs(Int(pixel.green) - Int(background.green))
            + abs(Int(pixel.blue) - Int(background.blue)) > 60
    }

    static func ms(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }
}
