import Foundation
import XCTest

@testable import RedScreenCore

@MainActor
final class ScreenshotImportControllerTests: XCTestCase {
    func testSuccessfulImportPublishesDocumentAndSession() async throws {
        let lifecycle = SecureImageSessionLifecycle(logger: silentLogger)
        let sink = RecordingSink()
        let controller = ScreenshotImportController(
            lifecycle: lifecycle,
            importer: StubImporter(),
            logger: PrivacySafeLogger(sink: sink)
        )

        await controller.importImage(from: url("a")).value

        let document = try XCTUnwrap(controller.document)
        XCTAssertFalse(controller.isImporting)
        XCTAssertNil(controller.lastError)
        XCTAssertEqual(document.pixelDimensions, try PixelDimensions(width: 2, height: 1))
        XCTAssertEqual(lifecycle.activeSession?.id, document.sessionID)
        XCTAssertTrue(controller.activePixels === lifecycle.activeSession?.decodedPixels)
        XCTAssertNil(lifecycle.activeSession?.sourceImage, "Encoded source must not be retained")
        XCTAssertEqual(
            lifecycle.activeSession?.redactionDocument?.pixelDimensions, document.pixelDimensions
        )
        XCTAssertEqual(sink.events, [.imageImported])
    }

    func testFailedImportsLeaveTheCurrentDocumentUntouched() async throws {
        let lifecycle = SecureImageSessionLifecycle(logger: silentLogger)
        let importer = StubImporter(failures: [
            "corrupt": .corruptImage,
            "unsupported": .unsupportedType,
            "empty": .zeroSizedImage,
            "huge": .pixelBudgetExceeded(limitPixels: 10),
        ])
        let controller = ScreenshotImportController(lifecycle: lifecycle, importer: importer)
        await controller.importImage(from: url("good")).value
        let original = try XCTUnwrap(controller.document)
        let originalSession = try XCTUnwrap(lifecycle.activeSession)
        let originalPixels = try XCTUnwrap(originalSession.decodedPixels)

        for (name, error) in importer.failures {
            await controller.importImage(from: url(name)).value

            XCTAssertEqual(controller.lastError, error)
            XCTAssertEqual(controller.document, original)
            XCTAssertTrue(lifecycle.activeSession === originalSession)
            XCTAssertTrue(originalSession.decodedPixels === originalPixels)
        }

        controller.dismissError()
        XCTAssertNil(controller.lastError)
    }

    func testStaleResultIsDiscardedWhenANewerImportFinishesFirst() async throws {
        let lifecycle = SecureImageSessionLifecycle(logger: silentLogger)
        let importer = GatedImporter()
        let controller = ScreenshotImportController(lifecycle: lifecycle, importer: importer)

        let slow = controller.importImage(from: url("slow"))
        await importer.waitUntilRequested("slow")
        let fast = controller.importImage(from: url("fast"))
        await importer.waitUntilRequested("fast")
        await importer.release("fast", width: 3)
        await fast.value
        let fastSession = try XCTUnwrap(lifecycle.activeSession)

        await importer.release("slow", width: 9)
        await slow.value

        XCTAssertTrue(lifecycle.activeSession === fastSession)
        XCTAssertEqual(controller.document?.pixelDimensions.width, 3)
        XCTAssertNil(controller.lastError)
    }

    func testClosingDocumentClearsSessionAndIgnoresInFlightImport() async throws {
        let lifecycle = SecureImageSessionLifecycle(logger: silentLogger)
        let importer = GatedImporter()
        let controller = ScreenshotImportController(lifecycle: lifecycle, importer: importer)
        let first = controller.importImage(from: url("first"))
        await importer.waitUntilRequested("first")
        await importer.release("first", width: 2)
        await first.value
        let session = try XCTUnwrap(lifecycle.activeSession)

        let pending = controller.importImage(from: url("pending"))
        await importer.waitUntilRequested("pending")
        XCTAssertTrue(controller.isImporting)
        controller.closeDocument()
        await importer.release("pending", width: 5)
        await pending.value

        XCTAssertNil(controller.document)
        XCTAssertNil(controller.activePixels)
        XCTAssertNil(lifecycle.activeSession)
        XCTAssertNil(session.decodedPixels)
        XCTAssertNil(session.redactionDocument)
        XCTAssertFalse(controller.isImporting)
    }

    func testCancellationDoesNotReportAnError() async throws {
        let lifecycle = SecureImageSessionLifecycle(logger: silentLogger)
        let controller = ScreenshotImportController(
            lifecycle: lifecycle, importer: StubImporter(cancelling: ["cancel"])
        )

        await controller.importImage(from: url("cancel")).value

        XCTAssertNil(controller.lastError)
        XCTAssertNil(controller.document)
        XCTAssertFalse(controller.isImporting)
    }

    func testDroppedItemsMustBeExactlyOneFileURL() async throws {
        let importer = StubImporter()
        let controller = ScreenshotImportController(
            lifecycle: SecureImageSessionLifecycle(logger: silentLogger), importer: importer
        )

        XCTAssertNil(controller.importDroppedItems([url("a"), url("b")]))
        XCTAssertEqual(controller.lastError, .multipleItems)
        XCTAssertNil(controller.importDroppedItems([URL(string: "https://example.test/a.png")!]))
        XCTAssertEqual(controller.lastError, .notAFile)
        XCTAssertNil(controller.importDroppedItems([]))
        XCTAssertEqual(controller.lastError, .notAFile)
        XCTAssertEqual(importer.requestCount, 0)

        await controller.importDroppedItems([url("dropped")])?.value
        XCTAssertNotNil(controller.document)
        XCTAssertNil(controller.lastError)
    }

    func testLifecycleRejectsImportWhoseLayoutDisagreesWithItsDimensions() throws {
        let lifecycle = SecureImageSessionLifecycle(logger: silentLogger)
        let layout = PixelBufferLayout(
            dimensions: try PixelDimensions(width: 1, height: 1), colorSpace: .sRGB
        )
        let mismatched = ImportedImage(
            sourceIdentity: SourceImageIdentity(),
            pixelDimensions: try PixelDimensions(width: 2, height: 2),
            pixels: DecodedPixels(bytes: Data(count: 4), layout: layout)
        )

        XCTAssertThrowsError(try lifecycle.createSession(importedImage: mismatched))
        XCTAssertNil(lifecycle.activeSession)
    }

    // MARK: - Helpers

    private var silentLogger: PrivacySafeLogger { PrivacySafeLogger(sink: RecordingSink()) }

    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/synthetic/\(name).png")
    }
}

private func makeImported(width: Int) throws -> ImportedImage {
    let dimensions = try PixelDimensions(width: width, height: 1)
    let layout = PixelBufferLayout(dimensions: dimensions, colorSpace: .sRGB)
    return ImportedImage(
        sourceIdentity: SourceImageIdentity(),
        pixelDimensions: dimensions,
        pixels: DecodedPixels(bytes: Data(count: layout.byteCount), layout: layout)
    )
}

private final class StubImporter: ImageImporter, @unchecked Sendable {
    let failures: [String: ImageImportError]
    private let cancelling: Set<String>
    private let lock = NSLock()
    private var requests = 0

    init(failures: [String: ImageImportError] = [:], cancelling: Set<String> = []) {
        self.failures = failures
        self.cancelling = cancelling
    }

    var requestCount: Int { lock.withLock { requests } }

    func importImage(from url: URL) async throws -> ImportedImage {
        lock.withLock { requests += 1 }
        let name = url.deletingPathExtension().lastPathComponent
        if cancelling.contains(name) { throw CancellationError() }
        if let failure = failures[name] { throw failure }
        return try makeImported(width: 2)
    }
}

/// Holds each import until the test releases it, to force completion order.
private actor GatedImporter: ImageImporter {
    private var waiting: [String: CheckedContinuation<ImportedImage, any Error>] = [:]
    private var requestWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func importImage(from url: URL) async throws -> ImportedImage {
        let name = url.deletingPathExtension().lastPathComponent
        return try await withCheckedThrowingContinuation { continuation in
            waiting[name] = continuation
            requestWaiters.removeValue(forKey: name)?.forEach { $0.resume() }
        }
    }

    func waitUntilRequested(_ name: String) async {
        if waiting[name] != nil { return }
        await withCheckedContinuation { requestWaiters[name, default: []].append($0) }
    }

    func release(_ name: String, width: Int) {
        do {
            waiting.removeValue(forKey: name)?.resume(returning: try makeImported(width: width))
        } catch {
            waiting.removeValue(forKey: name)?.resume(throwing: error)
        }
    }
}

private final class RecordingSink: PrivacyLogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [PrivacyLogEntry] = []

    var events: [PrivacyLogEvent] { lock.withLock { entries.map(\.event) } }

    func write(_ entry: PrivacyLogEntry) {
        lock.withLock { entries.append(entry) }
    }
}
