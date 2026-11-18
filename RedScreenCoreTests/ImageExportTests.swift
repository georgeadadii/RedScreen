import AppKit
import CoreGraphics
import Foundation
import ImageIO
import XCTest

@testable import RedScreenCore

/// RED-7: scrubbed PNG encoding, atomic file export, and pasteboard output.
final class ImageExportTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RedScreenExportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: - Encoding

    func testPNGRoundTripReproducesTheReviewedPixelsExactly() throws {
        for space in [RenderingColorSpace.sRGB, .displayP3] {
            let image = try redactedImage(width: 9, height: 5, colorSpace: space)
            let data = try ScrubbedPNGEncoder().encode(image)
            XCTAssertEqual(try decodedPixels(from: data, colorSpace: space), image.pixels.bytes, "\(space)")
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(decoded.colorSpace?.name, CGColorSpace(name: space.cgName)?.name)
        }
    }

    func testPNGContainsOnlyAllowlistedChunksAndNoInheritedMetadataOrThumbnail() throws {
        let data = try ScrubbedPNGEncoder().encode(try redactedImage(width: 64, height: 48, colorSpace: .sRGB))
        // Structural, not textual: every chunk must be pixel or colour data.
        let allowed: Set<String> = ["IHDR", "PLTE", "IDAT", "IEND", "iCCP", "sRGB", "gAMA", "cHRM", "pHYs"]
        let chunks = try pngChunkTypes(data)
        XCTAssertEqual(chunks.first, "IHDR")
        XCTAssertEqual(chunks.last, "IEND")
        XCTAssertTrue(Set(chunks).isSubset(of: allowed), "Unexpected chunks: \(Set(chunks).subtracting(allowed))")

        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 1)
        let container = CGImageSourceCopyProperties(source, nil) as? [CFString: Any] ?? [:]
        XCTAssertNil(container[kCGImagePropertyThumbnailImages])
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyExifAuxDictionary, kCGImagePropertyGPSDictionary,
                    kCGImagePropertyIPTCDictionary, kCGImagePropertyTIFFDictionary, kCGImagePropertyMakerAppleDictionary,
                    kCGImagePropertyThumbnailImages] {
            XCTAssertNil(properties[key], "\(key)")
        }
        let png = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any] ?? [:]
        for key in [kCGImagePropertyPNGDescription, kCGImagePropertyPNGComment, kCGImagePropertyPNGAuthor,
                    kCGImagePropertyPNGTitle, kCGImagePropertyPNGSoftware, kCGImagePropertyPNGCreationTime,
                    kCGImagePropertyPNGModificationTime, kCGImagePropertyPNGCopyright,
                    kCGImagePropertyPNGDisclaimer, kCGImagePropertyPNGWarning, kCGImagePropertyPNGSource] {
            XCTAssertNil(png[key], "\(key)")
        }
        if let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) {
            XCTAssertEqual(CGImageMetadataCopyTags(metadata).map { CFArrayGetCount($0) } ?? 0, 0)
        }
    }

    func testLargeImageStillDecodesExactlyAfterDroppingDecoderHints() throws {
        let image = try redactedImage(width: 1500, height: 1000, colorSpace: .sRGB)
        let data = try ScrubbedPNGEncoder().encode(image)
        XCTAssertFalse(try pngChunkTypes(data).contains("iDOT"))
        XCTAssertEqual(try decodedPixels(from: data, colorSpace: .sRGB), image.pixels.bytes)
    }

    func testChunkFilterRejectsMalformedPNG() throws {
        let valid = try ScrubbedPNGEncoder().encode(try redactedImage(width: 2, height: 2, colorSpace: .sRGB))
        for malformed in [Data("not a png".utf8), valid.prefix(valid.count - 3), valid + Data([0, 0, 0])] {
            XCTAssertThrowsError(try ScrubbedPNGEncoder.keepingAllowedChunks(malformed))
        }
        XCTAssertEqual(try ScrubbedPNGEncoder.keepingAllowedChunks(valid), valid)
    }

    func testEncoderRejectsPixelsWithoutALayout() {
        let image = FlattenedRedactedImage(
            renderedPixels: DecodedPixels(bytes: Data([1, 2, 3, 4])),
            sessionID: UUID(), reviewRevision: 0, importGeneration: 0
        )
        XCTAssertThrowsError(try ScrubbedPNGEncoder().encode(image)) {
            XCTAssertEqual($0 as? ImageExportError, .encodingFailed)
        }
    }

    // MARK: - File export

    func testExportWritesDecodablePNGAndRemovesStaging() async throws {
        let image = try redactedImage(width: 7, height: 3, colorSpace: .sRGB)
        let staging = StagingSpy(root: directory.appendingPathComponent("staging"))
        let output = destinationDirectory().appendingPathComponent("out.png")

        try await AtomicFileImageExporter(stagingDirectory: staging.provider)
            .export(image, to: ExportDestination(url: output))

        XCTAssertEqual(try decodedPixels(from: Data(contentsOf: output), colorSpace: .sRGB), image.pixels.bytes)
        XCTAssertEqual(try contents(of: output.deletingLastPathComponent()), ["out.png"])
        XCTAssertTrue(staging.allRemoved)
        XCTAssertEqual(staging.created.count, 1)
    }

    func testExistingFileIsNeverReplacedWithoutConfirmation() async throws {
        let output = destinationDirectory().appendingPathComponent("existing.png")
        let original = Data("previous file".utf8)
        try original.write(to: output)
        let staging = StagingSpy(root: directory.appendingPathComponent("staging"))

        await assertExportFails(.destinationExists) {
            try await AtomicFileImageExporter(stagingDirectory: staging.provider)
                .export(try self.redactedImage(width: 2, height: 2, colorSpace: .sRGB), to: ExportDestination(url: output))
        }
        XCTAssertEqual(try Data(contentsOf: output), original)
        XCTAssertTrue(staging.allRemoved)
    }

    func testFileCreatedAfterTheExistenceCheckIsNotOverwritten() async throws {
        let output = destinationDirectory().appendingPathComponent("race.png")
        let intruder = Data("created concurrently".utf8)
        let staging = StagingSpy(root: directory.appendingPathComponent("staging")) {
            try intruder.write(to: output)
        }
        await assertExportFails(.destinationExists) {
            try await AtomicFileImageExporter(stagingDirectory: staging.provider)
                .export(try self.redactedImage(width: 2, height: 2, colorSpace: .sRGB), to: ExportDestination(url: output))
        }
        XCTAssertEqual(try Data(contentsOf: output), intruder)
        XCTAssertTrue(staging.allRemoved)
    }

    func testConfirmedReplacementSwapsTheWholeFileAtomically() async throws {
        let output = destinationDirectory().appendingPathComponent("replace.png")
        try Data("previous file".utf8).write(to: output)
        let before = try inode(of: output)
        let image = try redactedImage(width: 4, height: 4, colorSpace: .displayP3)
        let staging = StagingSpy(root: directory.appendingPathComponent("staging"))

        try await AtomicFileImageExporter(stagingDirectory: staging.provider)
            .export(image, to: ExportDestination(url: output, replacesExistingItem: true))

        XCTAssertNotEqual(try inode(of: output), before, "Replacement is a rename of a complete new file")
        XCTAssertEqual(try decodedPixels(from: Data(contentsOf: output), colorSpace: .displayP3), image.pixels.bytes)
        XCTAssertEqual(try contents(of: output.deletingLastPathComponent()), ["replace.png"])
        XCTAssertTrue(staging.allRemoved)
    }

    func testEncodingFailureWritesNothing() async throws {
        let output = destinationDirectory().appendingPathComponent("never.png")
        let staging = StagingSpy(root: directory.appendingPathComponent("staging"))
        await assertExportFails(.encodingFailed) {
            try await AtomicFileImageExporter(encoder: FailingEncoder(), stagingDirectory: staging.provider)
                .export(try self.redactedImage(width: 2, height: 2, colorSpace: .sRGB), to: ExportDestination(url: output))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertTrue(staging.created.isEmpty)
    }

    func testUnwritableDestinationLeavesNoPartialFileOrStagingCopy() async throws {
        let locked = destinationDirectory()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let output = locked.appendingPathComponent("locked.png")
        let staging = StagingSpy(root: directory.appendingPathComponent("staging"))

        await assertExportFails(.writeFailed) {
            try await AtomicFileImageExporter(stagingDirectory: staging.provider)
                .export(try self.redactedImage(width: 2, height: 2, colorSpace: .sRGB), to: ExportDestination(url: output))
        }
        XCTAssertEqual(try contents(of: locked), [])
        XCTAssertTrue(staging.allRemoved)
    }

    func testMissingParentDirectoryAndDirectoryURLsFail() async throws {
        let missing = directory.appendingPathComponent("missing/out.png")
        let staging = StagingSpy(root: directory.appendingPathComponent("staging"))
        await assertExportFails(.writeFailed) {
            try await AtomicFileImageExporter(stagingDirectory: staging.provider)
                .export(try self.redactedImage(width: 2, height: 2, colorSpace: .sRGB), to: ExportDestination(url: missing))
        }
        await assertExportFails(.invalidDestination) {
            try await AtomicFileImageExporter(stagingDirectory: staging.provider).export(
                try self.redactedImage(width: 2, height: 2, colorSpace: .sRGB),
                to: ExportDestination(url: self.destinationDirectory(), replacesExistingItem: true)
            )
        }
        XCTAssertTrue(staging.allRemoved)
    }

    func testCancellationBeforeOrDuringExportLeavesNothingBehind() async throws {
        let output = destinationDirectory().appendingPathComponent("cancelled.png")
        let image = try redactedImage(width: 2, height: 2, colorSpace: .sRGB)
        let early = StagingSpy(root: directory.appendingPathComponent("early"))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await AtomicFileImageExporter(stagingDirectory: early.provider).export(image, to: ExportDestination(url: output))
        }
        await XCTAssertThrowsCancellation(try await task.value)
        XCTAssertTrue(early.created.isEmpty)

        // Cancelled after the staged file is written but before it is moved into place.
        let late = StagingSpy(root: directory.appendingPathComponent("late")) {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        let lateTask = Task {
            try await AtomicFileImageExporter(stagingDirectory: late.provider).export(image, to: ExportDestination(url: output))
        }
        await XCTAssertThrowsCancellation(try await lateTask.value)
        XCTAssertEqual(late.created.count, 1)
        XCTAssertTrue(late.allRemoved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testDestinationIsNeverDescribed() {
        let destination = ExportDestination(url: URL(fileURLWithPath: "/Users/person/Secret/out.png"),
                                            replacesExistingItem: true)
        XCTAssertFalse(String(reflecting: destination).contains("Secret"))
        let image = FlattenedRedactedImage(renderedPixels: DecodedPixels(bytes: Data()), sessionID: UUID(),
                                           reviewRevision: 0, importGeneration: 0)
        XCTAssertEqual(String(reflecting: image), "FlattenedRedactedImage(<redacted>)")
    }

    // MARK: - Pasteboard

    @MainActor
    func testPasteboardReceivesOnlyRenderedPNGData() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("RedScreenTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("previous", forType: .string)
        let image = try redactedImage(width: 6, height: 4, colorSpace: .sRGB)

        try PasteboardImageWriter(pasteboard: pasteboard).copy(image)

        // The written item declares PNG only. The pasteboard may also advertise system image
        // translations, which are generated from that PNG and must decode to the same pixels.
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 1)
        XCTAssertEqual(pasteboard.pasteboardItems?.first?.types, PasteboardImageWriter.approvedTypes)
        let systemTranslations: Set<String> = [
            NSPasteboard.PasteboardType.tiff.rawValue, "Apple PNG pasteboard type", "NeXT TIFF v4.0 pasteboard type"
        ]
        let advertised = Set(try XCTUnwrap(pasteboard.types).map(\.rawValue))
        XCTAssertTrue(advertised.isSubset(of: systemTranslations.union(PasteboardImageWriter.approvedTypes.map(\.rawValue))),
                      "Unexpected types: \(advertised)")
        XCTAssertNil(pasteboard.string(forType: .string))
        XCTAssertNil(pasteboard.data(forType: .fileURL))
        XCTAssertNil(pasteboard.data(forType: .URL))
        let data = try XCTUnwrap(pasteboard.data(forType: .png))
        XCTAssertEqual(data, try ScrubbedPNGEncoder().encode(image))
        XCTAssertEqual(try decodedPixels(from: data, colorSpace: .sRGB), image.pixels.bytes)
        if let tiff = pasteboard.data(forType: .tiff) {
            XCTAssertEqual(try decodedPixels(from: tiff, colorSpace: .sRGB), image.pixels.bytes)
        }
    }

    @MainActor
    func testFailedCopyLeavesThePreviousClipboardUntouched() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("RedScreenTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("previous", forType: .string)

        XCTAssertThrowsError(try PasteboardImageWriter(pasteboard: pasteboard, encoder: FailingEncoder())
            .copy(try redactedImage(width: 2, height: 2, colorSpace: .sRGB))) {
            XCTAssertEqual($0 as? ImageExportError, .encodingFailed)
        }
        XCTAssertEqual(pasteboard.string(forType: .string), "previous")
    }

    // MARK: - Helpers

    /// A varied opaque pattern whose first row is solid black, standing in for a rendered redaction
    /// (the renderer itself is covered by `SolidFillRedactionRendererTests`).
    private func redactedImage(width: Int, height: Int, colorSpace: RenderingColorSpace) throws -> FlattenedRedactedImage {
        let layout = PixelBufferLayout(dimensions: try PixelDimensions(width: width, height: height), colorSpace: colorSpace)
        var bytes = Data(count: layout.byteCount)
        for index in 0..<(width * height) {
            let redacted = index < width
            bytes[index * 4] = redacted ? 0 : UInt8((index * 37) % 256)
            bytes[index * 4 + 1] = redacted ? 0 : UInt8((index * 91 + 13) % 256)
            bytes[index * 4 + 2] = redacted ? 0 : UInt8((index * 53 + 101) % 256)
            bytes[index * 4 + 3] = 255
        }
        return FlattenedRedactedImage(renderedPixels: DecodedPixels(bytes: bytes, layout: layout),
                                      sessionID: UUID(), reviewRevision: 0, importGeneration: 0)
    }

    /// Decodes to RGBA8 premultiplied-last in `colorSpace`, the renderer's layout.
    private func decodedPixels(from data: Data, colorSpace: RenderingColorSpace) throws -> Data {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var bytes = Data(count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: XCTUnwrap(CGColorSpace(name: colorSpace.cgName)),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    private func pngChunkTypes(_ data: Data) throws -> [String] {
        let bytes = [UInt8](data)
        XCTAssertEqual(Array(bytes.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var types: [String] = []
        var offset = 8
        while offset + 8 <= bytes.count {
            let length = bytes[offset..<(offset + 4)].reduce(0) { $0 << 8 | Int($1) }
            types.append(try XCTUnwrap(String(bytes: bytes[(offset + 4)..<(offset + 8)], encoding: .ascii)))
            offset += 12 + length
        }
        XCTAssertEqual(offset, bytes.count, "Trailing bytes after the last chunk")
        return types
    }

    private func destinationDirectory() -> URL {
        let url = directory.appendingPathComponent("destination", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func contents(of url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
    }

    private func inode(of url: URL) throws -> UInt64 {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? UInt64)
    }

    private func assertExportFails(
        _ expected: ImageExportError,
        file: StaticString = #filePath, line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? ImageExportError, expected, file: file, line: line)
        }
    }

    private func XCTAssertThrowsCancellation(
        _ body: @autoclosure () async throws -> Void,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            try await body()
            XCTFail("Expected cancellation", file: file, line: line)
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)", file: file, line: line)
        }
    }
}

private struct FailingEncoder: RedactedImageEncoding {
    func encode(_ image: FlattenedRedactedImage) throws -> Data {
        throw CocoaError(.fileWriteUnknown)
    }
}

/// Creates staging directories under a test-owned root and reports whether they were removed.
private final class StagingSpy: @unchecked Sendable {
    private let lock = NSLock()
    private let root: URL
    private let onCreate: @Sendable () throws -> Void
    private var stored: [URL] = []

    init(root: URL, onCreate: @escaping @Sendable () throws -> Void = {}) {
        self.root = root
        self.onCreate = onCreate
    }

    var created: [URL] { lock.withLock { stored } }
    var allRemoved: Bool { created.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) } }

    var provider: AtomicFileImageExporter.StagingDirectoryProvider {
        { [self] _ in
            let url = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            lock.withLock { stored.append(url) }
            try onCreate()
            return url
        }
    }
}
