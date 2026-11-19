import AppKit
import Foundation
import ImageIO
import XCTest

@testable import RedScreenCore

/// RED-8: the complete Phase 1 pipeline with every production component (ImageIO import, Vision
/// OCR, contextual detection, geometric composition, solid-fill rendering, scrubbed PNG export,
/// pasteboard copy) on the committed synthetic corpus. Reports print fixture IDs, counts, and
/// durations only, never OCR text or pixels.
@MainActor
final class Phase1WorkflowIntegrationTests: XCTestCase {
    private var work: URL!

    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory
            .appendingPathComponent("RedScreenPhase1-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        if let work { try? FileManager.default.removeItem(at: work) }
    }

    func testCleanImportDetectsSecretsAllowsEditsAndSavesAndCopiesFlattenedImage() async throws {
        let fixture = try FixtureLibrary.bundled().fixture(id: "env-file-light-2x")
        let truth = fixture.groundTruth
        let input = work.appendingPathComponent("input.png")
        try fixture.imageData().write(to: input)
        let destination = work.appendingPathComponent("redacted.png")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("RedScreenPhase1-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let watched = FileInventory.watchedDirectories(excluding: work)
        let before = FileInventory.snapshot(watched)
        let startedAt = Date()
        let sink = RecordingSink()

        let controller = ScreenshotImportController(
            lifecycle: SecureImageSessionLifecycle(logger: PrivacySafeLogger(sink: sink)),
            importer: ImageIOImageImporter(),
            textRecognizer: VisionTextRecognizer(),
            secretDetector: ContextualSecretDetector(),
            candidateComposer: GeometricCandidateComposer(),
            imageExporter: AtomicFileImageExporter(),
            clipboard: PasteboardImageWriter(pasteboard: pasteboard),
            logger: PrivacySafeLogger(sink: sink)
        )

        // Import, OCR, detection, composition.
        XCTAssertEqual(controller.workflowState, .idle)
        await controller.importImage(from: input).value
        await controller.currentRecognition?.value
        await controller.currentDetection?.value
        XCTAssertEqual(controller.workflowState, .reviewing)
        let dimensions = try truth.pixelDimensions()
        XCTAssertEqual(controller.document?.pixelDimensions, dimensions)
        let source = try XCTUnwrap(controller.activePixels)
        let sensitive = truth.spans.filter { $0.expectation == .sensitive }
        XCTAssertFalse(sensitive.isEmpty)
        let candidates = try XCTUnwrap(controller.activeDocument?.candidates)
        XCTAssertGreaterThanOrEqual(candidates.count, sensitive.count, "Each expected secret produces a finding")

        // Review: resolve every pending finding, then edit with a manual rectangle.
        for candidate in candidates where candidate.disposition == .pending {
            XCTAssertTrue(controller.setReviewDisposition(.included, for: candidate.id))
        }
        let manualRect = try ImageRect(x: 8, y: Double(dimensions.height - 24), width: 40, height: 16)
        let manual = try XCTUnwrap(controller.addManualRedaction(manualRect))
        let moved = try ImageRect(x: 12, y: Double(dimensions.height - 24), width: 40, height: 16)
        XCTAssertTrue(controller.updateManualRedaction(manual, rect: moved))
        XCTAssertTrue(controller.canRenderReviewedImage)

        // Render, save, copy.
        let rendered = try await controller.renderReviewedImage()
        try await controller.exportReviewedImage(rendered, to: ExportDestination(url: destination))
        try controller.copyReviewedImage(rendered)
        XCTAssertEqual(controller.workflowState, .reviewing)

        let saved = try Data(contentsOf: destination)
        XCTAssertEqual(pasteboard.data(forType: .png), saved, "Saved and copied output are identical")
        let output = try decode(saved, colorSpace: .sRGB)
        XCTAssertEqual(output, rendered.pixels.bytes, "The saved file is exactly the reviewed render")
        let flattened = DecodedPixels(bytes: output, layout: source.layout)

        // Every ink pixel of every expected secret is now opaque black, as is the manual edit.
        var secretInk = 0
        for span in sensitive {
            for segment in span.segments {
                let rect = try segment.rect.imageRect(in: dimensions).enclosingPixelRect(in: dimensions)
                let background = dominantColor(in: rect, pixels: source)
                for y in rect.y..<(rect.y + rect.height) {
                    for x in rect.x..<(rect.x + rect.width) where isInk(source.pixel(x: x, y: y), background) {
                        secretInk += 1
                        XCTAssertEqual(flattened.pixel(x: x, y: y), .init(red: 0, green: 0, blue: 0, alpha: 255),
                                       "\(span.id) ink survives at \(x),\(y)")
                    }
                }
            }
        }
        XCTAssertGreaterThan(secretInk, 0)
        let manualPixels = try moved.enclosingPixelRect(in: dimensions)
        for y in manualPixels.y..<(manualPixels.y + manualPixels.height) {
            for x in manualPixels.x..<(manualPixels.x + manualPixels.width) {
                XCTAssertEqual(flattened.pixel(x: x, y: y).alpha, 255)
                XCTAssertEqual(flattened.pixel(x: x, y: y).red, 0)
            }
        }
        // Pixels no candidate touched are unchanged.
        XCTAssertNotEqual(output, source.bytes)

        // Privacy: the only files the run created are the user's input copy and the chosen
        // destination. Nothing new in temporary or cache directories is an image or OCR text.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path).sorted(),
                       ["input.png", "redacted.png"])
        let secretValues = sensitive.compactMap { truth.text(of: $0) }.filter { $0.count >= 8 }
        let workPath = work.resolvingSymlinksInPath().path + "/"
        for file in FileInventory.snapshot(watched).subtracting(before)
        where !file.resolvingSymlinksInPath().path.hasPrefix(workPath) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                  let modified = attributes[.modificationDate] as? Date, modified >= startedAt,
                  let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { continue }
            XCTAssertFalse(FileInventory.isImage(data), "Image written outside the destination: \(file.lastPathComponent)")
            let text = String(decoding: data, as: UTF8.self)
            XCTAssertFalse(secretValues.contains { text.contains($0) },
                           "Recognized secret text written to \(file.lastPathComponent)")
        }
        XCTAssertTrue(sink.events.contains(.redactedImageSaved))
        XCTAssertTrue(sink.events.contains(.redactedImageCopied))

        controller.closeDocument()
        XCTAssertEqual(controller.workflowState, .idle)
    }

    /// Records per-stage durations on the smallest and largest corpus screenshots. Ceilings are
    /// loose regression tripwires for shared CI machines; the measured baselines are recorded in
    /// docs/PHASE1_READINESS.md.
    func testStageTimingBaselinesOnSmallAndLargeFixtures() async throws {
        let fixtures = try FixtureLibrary.bundled().fixtures()
        let byArea = try fixtures.sorted {
            let a = try $0.decodedPixelSize(), b = try $1.decodedPixelSize()
            return a.width * a.height < b.width * b.height
        }
        for fixture in [byArea.first!, byArea.last!] {
            let clock = ContinuousClock()
            var timings: [(String, Duration)] = []
            func time<T>(_ stage: String, _ body: () async throws -> T) async rethrows -> T {
                let start = clock.now
                let result = try await body()
                timings.append((stage, clock.now - start))
                return result
            }
            let imported = try await time("import") { try await ImageIOImageImporter().importImage(from: fixture.imageURL) }
            let dimensions = imported.pixelDimensions
            let observations = try await time("ocr") {
                try await VisionTextRecognizer().recognizeText(in: imported.pixels, dimensions: dimensions)
            }
            let detections = try await time("detect") { try await ContextualSecretDetector().detectSecrets(in: observations) }
            let candidates = try await time("compose") {
                try GeometricCandidateComposer().composeCandidates(
                    from: detections, observations: observations, pixels: imported.pixels, dimensions: dimensions)
            }
            var document = try RedactionDocument(sourceIdentity: imported.sourceIdentity, pixelDimensions: dimensions)
                .replacingObservations(observations, processingState: .textRecognized)
                .replacingDetections(detections)
                .replacingCandidates(candidates)
            for candidate in candidates where candidate.disposition == .pending {
                document = try document.settingDisposition(.included, for: candidate.id)
            }
            let reviewed = document
            let rendered = try await time("render") {
                try await SolidFillRedactionRenderer().render(document: reviewed, sourceImage: imported.pixels)
            }
            let image = FlattenedRedactedImage(renderedPixels: rendered, sessionID: UUID(), reviewRevision: 0, importGeneration: 0)
            _ = try await time("encode") { try ScrubbedPNGEncoder().encode(image) }

            let summary = timings.map { "\($0.0)=\(String(format: "%.1f", precise($0.1)))ms" }.joined(separator: " ")
            print("Phase 1 timing \(fixture.id) \(dimensions.width)x\(dimensions.height): \(summary)")
            let ceilings: [String: Int] = ["import": 2_000, "ocr": 20_000, "detect": 2_000, "compose": 5_000,
                                           "render": 2_000, "encode": 3_000]
            for (stage, duration) in timings {
                XCTAssertLessThan(milliseconds(duration), ceilings[stage]!, "\(fixture.id) \(stage)")
            }
        }
    }

    /// Rendering and encoding a 5K Retina screenshot (5120×2880) with many fills, larger than any
    /// corpus fixture, to bound the output path for large screenshots.
    func testLargeScreenshotRenderAndEncodeBaseline() async throws {
        let dimensions = try PixelDimensions(width: 5120, height: 2880)
        let layout = PixelBufferLayout(dimensions: dimensions, colorSpace: .displayP3)
        var bytes = Data(count: layout.byteCount)
        bytes.withUnsafeMutableBytes { buffer in
            for index in stride(from: 0, to: buffer.count, by: 4) {
                buffer[index] = UInt8(truncatingIfNeeded: index >> 6)
                buffer[index + 1] = UInt8(truncatingIfNeeded: index >> 10)
                buffer[index + 2] = 0x80
                buffer[index + 3] = 255
            }
        }
        var document = try RedactionDocument(sourceIdentity: SourceImageIdentity(), pixelDimensions: dimensions)
        for row in 0..<40 {
            document = try document.addingManualRegion(
                RedactionRegion(rect: ImageRect(x: 200, y: Double(row * 70), width: 1800, height: 40)), candidateID: UUID())
        }
        let reviewed = document
        let clock = ContinuousClock()
        let start = clock.now
        let rendered = try await SolidFillRedactionRenderer().render(document: reviewed, sourceImage: DecodedPixels(bytes: bytes, layout: layout))
        let renderTime = clock.now - start
        let image = FlattenedRedactedImage(renderedPixels: rendered, sessionID: UUID(), reviewRevision: 0, importGeneration: 0)
        let encodeStart = clock.now
        let png = try ScrubbedPNGEncoder().encode(image)
        let encodeTime = clock.now - encodeStart
        print(String(format: "Phase 1 timing synthetic-5k 5120x2880: render=%.1fms encode=%.1fms (%d KB)",
                     precise(renderTime), precise(encodeTime), png.count / 1024))
        XCTAssertLessThan(milliseconds(renderTime), 3_000)
        XCTAssertLessThan(milliseconds(encodeTime), 10_000)
    }

    /// The privacy inventory must notice a stray image; otherwise its silence proves nothing.
    func testFileInventoryDetectsAnUnexpectedImage() throws {
        let watched = [FileManager.default.temporaryDirectory]
        let before = FileInventory.snapshot(watched)
        let stray = FileManager.default.temporaryDirectory.appendingPathComponent("RedScreenStray-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: stray) }
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: stray)
        let added = FileInventory.snapshot(watched).subtracting(before)
        XCTAssertTrue(added.contains(stray.standardizedFileURL))
        XCTAssertTrue(FileInventory.isImage(try Data(contentsOf: stray)))
        XCTAssertFalse(FileInventory.isImage(Data("plain".utf8)))
    }

    /// Security gate: no production source can reach the network or persist implicitly, and the
    /// sandbox grants only user-selected file access.
    func testProductionCodeHasNoNetworkingOrImplicitPersistence() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let sources = try ["RedScreen", "RedScreenCore"].flatMap { directory -> [URL] in
            let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root.appendingPathComponent(directory),
                                                                          includingPropertiesForKeys: nil))
            return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        }
        XCTAssertGreaterThan(sources.count, 10)
        let forbidden = ["URLSession", "URLRequest", "NWConnection", "import Network", "CFNetwork", "WKWebView",
                         "UserDefaults", "NSUbiquitous", "CloudKit", "NSDocumentController", "noteNewRecentDocument",
                         "NSKeyedArchiver", "JSONEncoder", "print(", "NSLog("]
        // The one exception: CapturePreferenceStore keeps two capture preferences (see
        // testCapturePreferencesAreTheOnlyPersistedState).
        let preferenceStore = "CapturePreferenceStore.swift"
        for source in sources {
            let text = try String(contentsOf: source, encoding: .utf8)
            for token in forbidden where !(token == "UserDefaults" && source.lastPathComponent == preferenceStore) {
                XCTAssertFalse(text.contains(token), "\(source.lastPathComponent) uses \(token)")
            }
        }

        let store = try XCTUnwrap(sources.first { $0.lastPathComponent == preferenceStore })
        let storeText = try String(contentsOf: store, encoding: .utf8)
        for token in ["Data", "CGImage", "URL", "ImportedImage", "Observation", "Codable", "archive"] {
            XCTAssertFalse(storeText.contains(token), "\(preferenceStore) must store only primitive preferences")
        }

        let entitlements = try XCTUnwrap(NSDictionary(contentsOf:
            root.appendingPathComponent("RedScreen/Resources/RedScreen.entitlements")) as? [String: Bool])
        XCTAssertEqual(entitlements, [
            "com.apple.security.app-sandbox": true,
            "com.apple.security.files.user-selected.read-write": true,
        ])
    }

    // MARK: - Helpers

    private func precise(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }

    private func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1_000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }

    private func decode(_ data: Data, colorSpace: RenderingColorSpace) throws -> Data {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var bytes = Data(count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: XCTUnwrap(CGColorSpace(name: colorSpace.cgName)),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    private func dominantColor(in rect: PixelRect, pixels: DecodedPixels) -> TestImageFactory.RGBA {
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

    private func isInk(_ pixel: TestImageFactory.RGBA, _ background: TestImageFactory.RGBA) -> Bool {
        abs(Int(pixel.red) - Int(background.red)) + abs(Int(pixel.green) - Int(background.green))
            + abs(Int(pixel.blue) - Int(background.blue)) > 60
    }
}

/// Lists regular files under directories a careless implementation might write to.
enum FileInventory {
    static func watchedDirectories(excluding excluded: URL) -> [URL] {
        let fileManager = FileManager.default
        var directories = [fileManager.temporaryDirectory]
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        for base in caches + support {
            for name in [Bundle.main.bundleIdentifier, "com.georgeadadi.RedScreen", "RedScreen"].compactMap({ $0 }) {
                directories.append(base.appendingPathComponent(name, isDirectory: true))
            }
        }
        return directories.filter { !$0.standardizedFileURL.path.hasPrefix(excluded.standardizedFileURL.path) }
    }

    static func snapshot(_ directories: [URL]) -> Set<URL> {
        var files = Set<URL>()
        for directory in directories {
            guard let enumerator = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsPackageDescendants], errorHandler: { _, _ in true }
            ) else { continue }
            for case let url as URL in enumerator
            where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                files.insert(url.standardizedFileURL)
            }
        }
        return files
    }

    static func isImage(_ data: Data) -> Bool {
        let prefixes: [[UInt8]] = [
            [0x89, 0x50, 0x4E, 0x47], [0xFF, 0xD8, 0xFF], [0x49, 0x49, 0x2A, 0x00], [0x4D, 0x4D, 0x00, 0x2A]
        ]
        let head = [UInt8](data.prefix(12))
        if prefixes.contains(where: { head.starts(with: $0) }) { return true }
        // HEIF family: "ftyp" at offset 4.
        return head.count >= 8 && head[4...7] == [0x66, 0x74, 0x79, 0x70]
    }
}

private final class RecordingSink: PrivacyLogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [PrivacyLogEvent] = []
    var events: [PrivacyLogEvent] { lock.withLock { stored } }
    func write(_ entry: PrivacyLogEntry) { lock.withLock { stored.append(entry.event) } }
}
