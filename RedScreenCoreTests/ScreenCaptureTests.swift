import CoreGraphics
import Foundation
import XCTest

@testable import RedScreenCore

/// RED-9: capture geometry, capture normalization, and controller capture behaviour against a
/// fake `ScreenCaptureService`.
final class CaptureGeometryTests: XCTestCase {
    /// Main display 1920×1080 @1x at the origin; a 1440×900 @2x display above-left of it with
    /// a negative origin; a 2560×1440 @2x display to the right.
    private let main = CaptureDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), scale: 1)
    private let upperLeft = CaptureDisplay(id: 2, frame: CGRect(x: -1440, y: -900, width: 1440, height: 900), scale: 2)
    private let right = CaptureDisplay(id: 3, frame: CGRect(x: 1920, y: 0, width: 2560, height: 1440), scale: 2)
    private var displays: [CaptureDisplay] { [main, upperLeft, right] }

    func testAppKitToCoreGraphicsFlipUsesTheMainDisplayHeight() {
        let appKit = CGRect(x: 100, y: 980, width: 200, height: 50)
        XCTAssertEqual(CaptureGeometry.coreGraphicsRect(fromAppKit: appKit, mainDisplayHeight: 1080),
                       CGRect(x: 100, y: 50, width: 200, height: 50))
        // A display above the main display has positive AppKit y and negative CG y.
        let above = CGRect(x: -1000, y: 1500, width: 100, height: 100)
        XCTAssertEqual(CaptureGeometry.coreGraphicsRect(fromAppKit: above, mainDisplayHeight: 1080).minY, -520)
    }

    func testRegionOnOneXDisplayKeepsPointsAsPixels() throws {
        let plan = try CaptureGeometry.plan(region: CGRect(x: 10, y: 20, width: 300, height: 200), displays: displays)
        XCTAssertEqual(plan.displayID, 1)
        XCTAssertEqual(plan.sourceRect, CGRect(x: 10, y: 20, width: 300, height: 200))
        XCTAssertEqual(plan.pixelWidth, 300)
        XCTAssertEqual(plan.pixelHeight, 200)
    }

    func testRegionOnNegativeOriginRetinaDisplayIsLocalAndAtNativeScale() throws {
        let plan = try CaptureGeometry.plan(region: CGRect(x: -1400, y: -880, width: 100.25, height: 50.75),
                                            displays: displays)
        XCTAssertEqual(plan.displayID, 2)
        // Local origin (40, 20); fractional far edges round outward to whole device pixels.
        XCTAssertEqual(plan.sourceRect, CGRect(x: 40, y: 20, width: 100.5, height: 51))
        XCTAssertEqual(plan.pixelWidth, 201)
        XCTAssertEqual(plan.pixelHeight, 102)
    }

    func testFractionalOriginAlignsOutwardToDevicePixels() throws {
        let plan = try CaptureGeometry.plan(region: CGRect(x: 2000.3, y: 10.6, width: 10, height: 10), displays: displays)
        XCTAssertEqual(plan.displayID, 3)
        XCTAssertEqual(plan.sourceRect.minX, 80, accuracy: 1e-9)
        XCTAssertEqual(plan.sourceRect.minY, 10.5, accuracy: 1e-9)
        XCTAssertEqual(plan.sourceRect.maxX, 90.5, accuracy: 1e-9)
        XCTAssertEqual(plan.sourceRect.maxY, 21, accuracy: 1e-9)
        XCTAssertEqual(plan.pixelWidth, 21)
        XCTAssertEqual(plan.pixelHeight, 21)
    }

    func testRegionSpanningMixedScaleDisplaysUsesTheLargerOverlapAndClips() throws {
        // 100 pt on the 1x main display, 300 pt on the 2x right display.
        let plan = try CaptureGeometry.plan(region: CGRect(x: 1820, y: 100, width: 400, height: 100), displays: displays)
        XCTAssertEqual(plan.displayID, 3)
        XCTAssertEqual(plan.sourceRect, CGRect(x: 0, y: 100, width: 300, height: 100))
        XCTAssertEqual(plan.pixelWidth, 600)
        XCTAssertEqual(plan.pixelHeight, 200)
    }

    func testRegionIsClampedToTheDisplayEdges() throws {
        let plan = try CaptureGeometry.plan(region: CGRect(x: 1900, y: 1000, width: 100, height: 200),
                                            displays: [main])
        XCTAssertEqual(plan.sourceRect, CGRect(x: 1900, y: 1000, width: 20, height: 80))
    }

    func testEmptyOrOffscreenRegionsAreRejected() {
        for region in [CGRect(x: 10, y: 10, width: 0, height: 5), CGRect(x: 5000, y: 5000, width: 10, height: 10)] {
            XCTAssertThrowsError(try CaptureGeometry.plan(region: region, displays: displays)) {
                XCTAssertEqual($0 as? CaptureError, .emptyRegion)
            }
        }
        // A reversed (negative-size) drag is standardized, not rejected.
        XCTAssertNoThrow(try CaptureGeometry.plan(region: CGRect(x: 50, y: 50, width: -20, height: -20), displays: displays))
    }

    func testPixelSizeRoundsUpAtBackingScale() {
        XCTAssertTrue(CaptureGeometry.pixelSize(of: CGSize(width: 800.5, height: 600), scale: 2) == (1601, 1200))
        XCTAssertTrue(CaptureGeometry.pixelSize(of: CGSize(width: 800.5, height: 600), scale: 1) == (801, 600))
    }

    func testCaptureMessagesAreActionableAndNonIdentifying() {
        let cases: [CaptureError] = [.canceled, .permissionDenied, .permissionRestricted, .targetUnavailable, .protectedContent,
                                     .displayConfigurationChanged, .emptyRegion, .tooLarge, .failed]
        for error in cases {
            XCTAssertFalse(error.userMessage.isEmpty)
            XCTAssertFalse(error.userMessage.contains("/"))
        }
        XCTAssertTrue(CaptureError.permissionDenied.userMessage.contains("Screen & System Audio Recording"))
    }
}

final class CapturedImageNormalizerTests: XCTestCase {
    func testCaptureKeepsExactPixelsSizeAndColorSpace() throws {
        for space in [CGColorSpace.sRGB, CGColorSpace.displayP3] {
            let image = try makeImage(width: 7, height: 3, colorSpace: space, alpha: 255)
            let imported = try CapturedImageNormalizer.normalize(image, treatsTransparentAsProtected: true)
            XCTAssertEqual(imported.pixelDimensions, try PixelDimensions(width: 7, height: 3))
            XCTAssertEqual(imported.pixels.layout?.colorSpace, space == CGColorSpace.sRGB ? .sRGB : .displayP3)
            // Row 0 is the top row: the first pixel's red channel encodes (x: 0, y: 0).
            XCTAssertEqual(imported.pixels.pixel(x: 0, y: 0).red, 0)
            XCTAssertEqual(imported.pixels.pixel(x: 6, y: 2).red, 6 * 10)
            XCTAssertEqual(imported.pixels.pixel(x: 6, y: 2).green, 2 * 10)
        }
    }

    func testFullyTransparentWindowCaptureIsProtectedContent() throws {
        let image = try makeImage(width: 4, height: 4, colorSpace: CGColorSpace.sRGB, alpha: 0)
        XCTAssertThrowsError(try CapturedImageNormalizer.normalize(image, treatsTransparentAsProtected: true)) {
            XCTAssertEqual($0 as? CaptureError, .protectedContent)
        }
        XCTAssertNoThrow(try CapturedImageNormalizer.normalize(image, treatsTransparentAsProtected: false))
    }

    func testCaptureLargerThanTheImportBudgetIsRejectedBeforeDrawing() throws {
        let image = try makeImage(width: 20, height: 20, colorSpace: CGColorSpace.sRGB, alpha: 255)
        let policy = ImageImportPolicy(maximumFileBytes: 1, maximumDimension: 16_384, maximumPixelCount: 100)
        XCTAssertThrowsError(try CapturedImageNormalizer.normalize(image, policy: policy, treatsTransparentAsProtected: false)) {
            XCTAssertEqual($0 as? CaptureError, .tooLarge)
        }
    }

    /// Pixel (x, y) has red = 10x, green = 10y.
    private func makeImage(width: Int, height: Int, colorSpace: CFString, alpha: UInt8) throws -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                bytes[offset] = alpha == 0 ? 0 : UInt8(x * 10)
                bytes[offset + 1] = alpha == 0 ? 0 : UInt8(y * 10)
                bytes[offset + 2] = 0
                bytes[offset + 3] = alpha
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: XCTUnwrap(CGColorSpace(name: colorSpace)),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }
}

@MainActor
final class ScreenCaptureControllerTests: XCTestCase {
    func testCaptureOpensANewDocumentReadyForReview() async throws {
        let capturer = FakeCapturer()
        let (controller, sink) = makeController(capturer)
        capturer.results = [.success(try frame(width: 12))]
        let task = try XCTUnwrap(controller.captureScreenshot(.display(id: 1)))
        XCTAssertEqual(controller.workflowState, .loading)
        await task.value
        await controller.currentRecognition?.value
        await controller.currentDetection?.value
        XCTAssertEqual(controller.workflowState, .reviewing)
        XCTAssertEqual(controller.document?.pixelDimensions.width, 12)
        XCTAssertEqual(capturer.targets, [.display(id: 1)])
        XCTAssertTrue(sink.events.contains(.screenCaptured))
        XCTAssertFalse(sink.events.contains(.imageImported))
    }

    func testCanceledCaptureKeepsTheOpenDocumentAndReportsNothing() async throws {
        let capturer = FakeCapturer()
        let (controller, _) = makeController(capturer)
        try await openDocument(controller, capturer, width: 10)
        let open = try XCTUnwrap(controller.activeDocument)
        let pixels = controller.activePixels

        for canceled in [CaptureError.canceled] as [any Error] + [CancellationError()] {
            capturer.results = [.failure(canceled)]
            await controller.captureScreenshot(.region(CGRect(x: 0, y: 0, width: 5, height: 5)))?.value
            XCTAssertNil(controller.lastCaptureError)
            XCTAssertEqual(controller.activeDocument, open)
            XCTAssertEqual(controller.activePixels, pixels)
            XCTAssertEqual(controller.workflowState, .reviewing)
        }
        controller.reportCaptureFailure(.canceled)
        XCTAssertNil(controller.lastCaptureError)
    }

    func testPermissionDenialAndMissingTargetsAreRecoverable() async throws {
        let capturer = FakeCapturer()
        let (controller, sink) = makeController(capturer)
        capturer.results = [.failure(CaptureError.permissionDenied)]
        await controller.captureScreenshot(.display(id: 1))?.value
        XCTAssertEqual(controller.workflowState, .failed(.captureFailed(.permissionDenied)))
        XCTAssertNil(controller.document)

        // Recover: grant permission and capture again.
        capturer.results = [.success(try frame(width: 9))]
        await controller.captureScreenshot(.display(id: 1))?.value
        XCTAssertNil(controller.lastCaptureError)
        XCTAssertEqual(controller.document?.pixelDimensions.width, 9)

        // A window that disappeared reports an error but keeps the open document.
        await controller.currentRecognition?.value
        await controller.currentDetection?.value
        capturer.results = [.failure(CaptureError.targetUnavailable)]
        await controller.captureScreenshot(.window(id: 42))?.value
        XCTAssertEqual(controller.lastCaptureError, .targetUnavailable)
        XCTAssertEqual(controller.document?.pixelDimensions.width, 9)
        XCTAssertEqual(controller.workflowState, .reviewing)
        controller.dismissError()
        XCTAssertNil(controller.lastCaptureError)

        // Unknown platform errors become a generic, non-identifying failure.
        capturer.results = [.failure(CocoaError(.featureUnsupported))]
        await controller.captureScreenshot(.display(id: 1))?.value
        XCTAssertEqual(controller.lastCaptureError, .failed)
        XCTAssertEqual(sink.events.filter { $0 == .captureFailed }.count, 3)
    }

    func testSelectionTimeFailuresAreReported() {
        let (controller, _) = makeController(FakeCapturer())
        controller.reportCaptureFailure(.displayConfigurationChanged)
        XCTAssertEqual(controller.workflowState, .failed(.captureFailed(.displayConfigurationChanged)))
        controller.closeDocument()
        XCTAssertEqual(controller.workflowState, .idle)
    }

    func testStaleCaptureIsDiscardedWhenANewerImportWins() async throws {
        let capturer = FakeCapturer()
        capturer.holds = true
        let (controller, _) = makeController(capturer)
        let capture = try XCTUnwrap(controller.captureScreenshot(.display(id: 1)))
        await capturer.waitUntilRequested()
        let newer = controller.importImage(from: URL(fileURLWithPath: "/synthetic/15.png"))
        await newer.value
        capturer.release(.success(try frame(width: 30)))
        await capture.value
        XCTAssertEqual(controller.document?.pixelDimensions.width, 15)
    }

    func testCancelingAnInFlightCaptureKeepsTheOpenDocument() async throws {
        let capturer = FakeCapturer()
        let (controller, _) = makeController(capturer)
        try await openDocument(controller, capturer, width: 10)
        let open = controller.document
        capturer.holds = true
        let capture = try XCTUnwrap(controller.captureScreenshot(.display(id: 1)))
        await capturer.waitUntilRequested()
        controller.cancelProcessing()
        capturer.release(.success(try frame(width: 40)))
        await capture.value
        XCTAssertEqual(controller.document, open)
        XCTAssertEqual(controller.workflowState, .reviewing)
    }

    func testCaptureWritesNoFiles() async throws {
        let watched = FileInventory.watchedDirectories(excluding: URL(fileURLWithPath: "/nonexistent"))
        let before = FileInventory.snapshot(watched)
        let started = Date()
        let capturer = FakeCapturer()
        let (controller, _) = makeController(capturer)
        capturer.results = [.success(try frame(width: 64))]
        await controller.captureScreenshot(.display(id: 1))?.value
        await controller.currentRecognition?.value
        await controller.currentDetection?.value
        controller.closeDocument()
        for file in FileInventory.snapshot(watched).subtracting(before) {
            guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  modified >= started, let data = try? Data(contentsOf: file) else { continue }
            XCTAssertFalse(FileInventory.isImage(data), "Capture wrote an image: \(file.lastPathComponent)")
        }
    }

    /// ScreenCaptureKit stays in the app target; capture code writes no files and logs nothing.
    func testScreenCaptureKitIsConfinedToTheAppCaptureLayer() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let core = try XCTUnwrap(FileManager.default.enumerator(at: root.appendingPathComponent("RedScreenCore"),
                                                                includingPropertiesForKeys: nil))
        for case let url as URL in core where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(text.contains("ScreenCaptureKit"), url.lastPathComponent)
            XCTAssertFalse(text.contains("CGRequestScreenCaptureAccess"), url.lastPathComponent)
        }
        for name in ["ScreenCaptureKitService.swift", "RegionSelectionOverlay.swift"] {
            let text = try String(contentsOf: root.appendingPathComponent("RedScreen/Capture/\(name)"), encoding: .utf8)
            for token in ["FileManager", ".write(", "Logger(", "PrivacySafeLogger", "UserDefaults", "print("] {
                XCTAssertFalse(text.contains(token), "\(name) uses \(token)")
            }
        }
    }

    // MARK: - Helpers

    private func makeController(_ capturer: FakeCapturer) -> (ScreenshotImportController, EventRecorder) {
        let sink = EventRecorder()
        let controller = ScreenshotImportController(
            lifecycle: SecureImageSessionLifecycle(logger: PrivacySafeLogger(sink: EventRecorder())),
            importer: SizedImporter(),
            screenCapturer: capturer,
            textRecognizer: NoTextRecognizer(),
            secretDetector: ContextualSecretDetector(),
            candidateComposer: GeometricCandidateComposer(),
            logger: PrivacySafeLogger(sink: sink)
        )
        return (controller, sink)
    }

    private func openDocument(_ controller: ScreenshotImportController, _ capturer: FakeCapturer, width: Int) async throws {
        capturer.results = [.success(try frame(width: width))]
        await controller.captureScreenshot(.display(id: 1))?.value
        await controller.currentRecognition?.value
        await controller.currentDetection?.value
        XCTAssertEqual(controller.workflowState, .reviewing)
    }

    private func frame(width: Int) throws -> ImportedImage {
        let layout = PixelBufferLayout(dimensions: try PixelDimensions(width: width, height: 8), colorSpace: .sRGB)
        return ImportedImage(sourceIdentity: SourceImageIdentity(), pixelDimensions: layout.dimensions,
                             pixels: DecodedPixels(bytes: Data(repeating: 0xEE, count: layout.byteCount), layout: layout))
    }
}

// MARK: - Fakes

/// Returns queued results, or parks the request until `release` when `holds` is set.
/// Like a slow platform capture, a parked request ignores cancellation.
private final class FakeCapturer: ScreenCaptureService, @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [Result<ImportedImage, any Error>] = []
    private var recorded: [CaptureTarget] = []
    private var parked: CheckedContinuation<Result<ImportedImage, any Error>, Never>?
    private var requestWaiter: CheckedContinuation<Void, Never>?
    private var holding = false

    var results: [Result<ImportedImage, any Error>] {
        get { lock.withLock { queued } }
        set { lock.withLock { queued = newValue } }
    }
    var holds: Bool {
        get { lock.withLock { holding } }
        set { lock.withLock { holding = newValue } }
    }
    var targets: [CaptureTarget] { lock.withLock { recorded } }

    func capture(_ target: CaptureTarget) async throws -> ImportedImage {
        let immediate: Result<ImportedImage, any Error>? = lock.withLock {
            recorded.append(target)
            return holding ? nil : (queued.isEmpty ? .failure(CaptureError.failed) : queued.removeFirst())
        }
        if let immediate { return try immediate.get() }
        let result = await withCheckedContinuation { continuation in
            let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                parked = continuation
                defer { requestWaiter = nil }
                return requestWaiter
            }
            waiter?.resume()
        }
        return try result.get()
    }

    func waitUntilRequested() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { () -> Bool in
                if parked != nil { return true }
                requestWaiter = continuation
                return false
            }
            if ready { continuation.resume() }
        }
    }

    func release(_ result: Result<ImportedImage, any Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<Result<ImportedImage, any Error>, Never>? in
            defer { parked = nil }
            return parked
        }
        continuation?.resume(returning: result)
    }
}

/// Imports `/synthetic/<width>.png` as a width × 8 image.
private struct SizedImporter: ImageImporter {
    func importImage(from url: URL) async throws -> ImportedImage {
        let width = Int(url.deletingPathExtension().lastPathComponent) ?? 1
        let layout = PixelBufferLayout(dimensions: try PixelDimensions(width: width, height: 8), colorSpace: .sRGB)
        return ImportedImage(sourceIdentity: SourceImageIdentity(), pixelDimensions: layout.dimensions,
                             pixels: DecodedPixels(bytes: Data(count: layout.byteCount), layout: layout))
    }
}

private struct NoTextRecognizer: TextRecognizer {
    func recognizeText(in pixels: DecodedPixels, dimensions: PixelDimensions) async throws -> [OCRObservation] { [] }
}

private final class EventRecorder: PrivacyLogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [PrivacyLogEvent] = []
    var events: [PrivacyLogEvent] { lock.withLock { stored } }
    func write(_ entry: PrivacyLogEntry) { lock.withLock { stored.append(entry.event) } }
}
