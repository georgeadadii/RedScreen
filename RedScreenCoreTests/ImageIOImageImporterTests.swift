import CoreGraphics
import Foundation
import ImageIO
import XCTest

@testable import RedScreenCore

final class ImageIOImageImporterTests: XCTestCase {
    private typealias RGBA = TestImageFactory.RGBA

    private var directory: TemporaryTestDirectory!

    override func setUpWithError() throws {
        directory = try TemporaryTestDirectory()
    }

    override func tearDown() {
        directory = nil
    }

    // MARK: - Supported formats

    func testImportsPNGJPEGAndHEICIntoCanonicalUprightRGBA() async throws {
        let image = TestImageFactory.makeImage(blocks: [[.red, .green], [.blue, .white]])
        let formats: [(SupportedImageFormat, Int)] = [(.png, 0), (.jpeg, 12), (.heic, 24)]

        for (format, tolerance) in formats {
            let data = try TestImageFactory.encode(image, as: format.typeIdentifier)
            let url = try directory.write(data, named: "sample.\(format)")

            let imported = try await ImageIOImageImporter().importImage(from: url)
            let layout = try XCTUnwrap(imported.pixels.layout)

            XCTAssertEqual(imported.pixelDimensions, try PixelDimensions(width: 16, height: 16))
            XCTAssertEqual(layout.dimensions, imported.pixelDimensions)
            XCTAssertEqual(layout.pixelFormat, .rgba8PremultipliedLast)
            XCTAssertEqual(layout.colorSpace, .sRGB)
            XCTAssertEqual(imported.pixels.bytes.count, 16 * 16 * 4)
            for (x, y, expected) in [(4, 4, RGBA.red), (12, 4, .green), (4, 12, .blue), (12, 12, .white)] {
                let actual = imported.pixels.pixel(x: x, y: y)
                XCTAssertTrue(
                    actual.isClose(to: expected, tolerance: tolerance),
                    "\(format) at (\(x), \(y)): \(actual) != \(expected)"
                )
            }
        }
    }

    func testFormatIsDetectedFromContentsNotFileExtension() async throws {
        let png = try TestImageFactory.encode(
            TestImageFactory.makeImage(blocks: [[.red]]), as: SupportedImageFormat.png.typeIdentifier
        )
        let misnamed = try directory.write(png, named: "actually-a-png.jpg")
        let imported = try await ImageIOImageImporter().importImage(from: misnamed)
        XCTAssertEqual(imported.pixelDimensions.width, 8)

        let gif = try TestImageFactory.encode(
            TestImageFactory.makeImage(blocks: [[.red]]), as: "com.compuserve.gif"
        )
        let disguised = try directory.write(gif, named: "disguised.png")
        await assertImportFails(disguised, with: .unsupportedType)
    }

    func testPreservesAlphaChannel() async throws {
        let translucent = RGBA(red: 0, green: 0, blue: 255, alpha: 128)
        let image = TestImageFactory.makeImage(
            blocks: [[.red, translucent], [RGBA(red: 0, green: 0, blue: 0, alpha: 0), .white]],
            alpha: true
        )
        let url = try directory.write(
            try TestImageFactory.encode(image, as: SupportedImageFormat.png.typeIdentifier),
            named: "alpha.png"
        )

        let pixels = try await ImageIOImageImporter().importImage(from: url).pixels

        XCTAssertEqual(pixels.pixel(x: 4, y: 4), .red)
        XCTAssertTrue(pixels.pixel(x: 12, y: 4).isClose(to: translucent, tolerance: 3))
        XCTAssertEqual(pixels.pixel(x: 4, y: 12).alpha, 0)
        XCTAssertEqual(pixels.pixel(x: 12, y: 12), .white)
    }

    func testWideGamutInputIsRetainedInDisplayP3() async throws {
        let image = TestImageFactory.makeImage(
            blocks: [[.green, .red]], colorSpace: CGColorSpace.displayP3
        )
        let url = try directory.write(
            try TestImageFactory.encode(image, as: SupportedImageFormat.png.typeIdentifier),
            named: "p3.png"
        )

        let pixels = try await ImageIOImageImporter().importImage(from: url).pixels

        XCTAssertEqual(pixels.layout?.colorSpace, .displayP3)
        // Fully saturated P3 green survives unclipped because no sRGB conversion happens.
        XCTAssertTrue(pixels.pixel(x: 4, y: 4).isClose(to: .green, tolerance: 1))
        XCTAssertTrue(pixels.pixel(x: 12, y: 4).isClose(to: .red, tolerance: 1))
    }

    func testNonRGBInputIsConvertedToSRGB() throws {
        XCTAssertEqual(
            ImageIOImageImporter.renderingColorSpace(for: CGColorSpace(name: CGColorSpace.linearGray)),
            .sRGB
        )
        XCTAssertEqual(ImageIOImageImporter.renderingColorSpace(for: nil), .sRGB)
        XCTAssertEqual(
            ImageIOImageImporter.renderingColorSpace(for: CGColorSpace(name: CGColorSpace.sRGB)),
            .sRGB
        )
        XCTAssertEqual(
            ImageIOImageImporter.renderingColorSpace(
                for: CGColorSpace(name: CGColorSpace.displayP3)
            ),
            .displayP3
        )
    }

    // MARK: - Orientation

    func testAllEXIFOrientationsNormalizeToUprightPixels() async throws {
        // Stored image: 3 columns × 2 rows of distinct colours.
        let stored: [[RGBA]] = [[.red, .green, .blue], [.white, .black, .yellow]]
        let image = TestImageFactory.makeImage(blocks: stored, blockSize: 8)

        for orientation in 1...8 {
            let data = try TestImageFactory.encode(
                image, as: SupportedImageFormat.jpeg.typeIdentifier, orientation: orientation
            )
            let url = try directory.write(data, named: "orientation-\(orientation).jpg")
            let imported = try await ImageIOImageImporter().importImage(from: url)
            let expected = Self.display(stored, orientation: orientation)

            XCTAssertEqual(imported.pixelDimensions.width, expected[0].count * 8, "\(orientation)")
            XCTAssertEqual(imported.pixelDimensions.height, expected.count * 8, "\(orientation)")
            for (row, colors) in expected.enumerated() {
                for (column, color) in colors.enumerated() {
                    let actual = imported.pixels.pixel(x: column * 8 + 4, y: row * 8 + 4)
                    XCTAssertTrue(
                        actual.isClose(to: color, tolerance: 24),
                        "orientation \(orientation) block (\(row), \(column)): \(actual) != \(color)"
                    )
                }
            }
        }
    }

    /// Applies the TIFF/EXIF orientation definition independently of ImageIO.
    private static func display(_ stored: [[RGBA]], orientation: Int) -> [[RGBA]] {
        let height = stored.count
        let width = stored[0].count
        let swaps = (5...8).contains(orientation)
        let displayRows = swaps ? width : height
        let displayColumns = swaps ? height : width
        var result = Array(
            repeating: Array(repeating: RGBA.black, count: displayColumns), count: displayRows
        )
        for r in 0..<height {
            for c in 0..<width {
                let (row, column): (Int, Int) = switch orientation {
                case 1: (r, c)
                case 2: (r, width - 1 - c)
                case 3: (height - 1 - r, width - 1 - c)
                case 4: (height - 1 - r, c)
                case 5: (c, r)
                case 6: (c, height - 1 - r)
                case 7: (width - 1 - c, height - 1 - r)
                default: (width - 1 - c, r)
                }
                result[row][column] = stored[r][c]
            }
        }
        return result
    }

    // MARK: - Synthetic screenshot fixtures

    func testImportsEverySyntheticFixtureAtItsGroundTruthSize() async throws {
        let library = try FixtureLibrary.bundled()
        let fixtures = try library.fixtures()
        XCTAssertTrue(Set(fixtures.map(\.groundTruth.scale)).isSuperset(of: [1, 2]))

        for fixture in fixtures {
            let imported = try await ImageIOImageImporter().importImage(from: fixture.imageURL)
            let truth = fixture.groundTruth
            XCTAssertEqual(imported.pixelDimensions, try truth.pixelDimensions(), fixture.id)
            XCTAssertEqual(imported.pixels.layout?.colorSpace, .sRGB, fixture.id)

            // Ground-truth boxes land on the same upright pixels: each contains ink.
            let background = imported.pixels.pixel(x: 1, y: 1)
            let box = try XCTUnwrap(truth.textBoxes.first)
            let rect = try box.rect.imageRect(in: imported.pixelDimensions)
                .enclosingPixelRect(in: imported.pixelDimensions)
            var ink = 0
            for y in rect.y..<(rect.y + rect.height) {
                for x in rect.x..<(rect.x + rect.width)
                where !imported.pixels.pixel(x: x, y: y).isClose(to: background, tolerance: 8) {
                    ink += 1
                }
            }
            XCTAssertGreaterThan(ink, 0, fixture.id)
        }
    }

    // MARK: - Rejections

    func testRejectsEmptyMissingDirectoryAndNonFileURLs() async throws {
        await assertImportFails(try directory.write(Data(), named: "empty.png"), with: .emptyFile)
        await assertImportFails(
            directory.url.appendingPathComponent("missing.png"), with: .unreadable
        )
        await assertImportFails(directory.url, with: .notAFile)
        await assertImportFails(URL(string: "https://example.test/image.png")!, with: .notAFile)
    }

    func testRejectsCorruptAndTruncatedImages() async throws {
        let png = try TestImageFactory.encode(
            TestImageFactory.makeImage(blocks: [[.red, .green], [.blue, .white]], blockSize: 64),
            as: SupportedImageFormat.png.typeIdentifier
        )
        let truncated = try directory.write(png.prefix(png.count / 2), named: "truncated.png")
        await assertImportFails(truncated, with: .corruptImage)

        let garbage = try directory.write(Data("not an image at all".utf8), named: "garbage.png")
        await assertImportFails(garbage, with: .unsupportedType)

        var damaged = png
        let start = 64
        damaged.replaceSubrange(start..<(start + 200), with: Data(repeating: 0xA5, count: 200))
        let damagedURL = try directory.write(damaged, named: "damaged.png")
        await assertImportFails(damagedURL, with: .corruptImage)

        let image = TestImageFactory.makeImage(blocks: [[.red, .green], [.blue, .white]], blockSize: 64)
        for format in [SupportedImageFormat.jpeg, .heic] {
            let encoded = try TestImageFactory.encode(image, as: format.typeIdentifier)
            let url = try directory.write(encoded.prefix(encoded.count * 2 / 3), named: "cut.\(format)")
            await assertImportFails(url, with: .corruptImage)
        }
    }

    func testRejectsZeroSizedImageHeader() async throws {
        let url = try directory.write(Self.pngHeader(width: 0, height: 10), named: "zero.png")
        do {
            _ = try await ImageIOImageImporter().importImage(from: url)
            XCTFail("Zero-sized image was accepted")
        } catch let error as ImageImportError {
            // ImageIO may refuse to identify an invalid IHDR at all; either way it is rejected.
            XCTAssertTrue([.zeroSizedImage, .unsupportedType].contains(error), "\(error)")
        }
    }

    func testRejectsOverBudgetImagesBeforeDecoding() async throws {
        let png = try TestImageFactory.encode(
            TestImageFactory.makeImage(blocks: [[.red]], blockSize: 40),
            as: SupportedImageFormat.png.typeIdentifier
        )
        let url = try directory.write(png, named: "40x40.png")

        await assertImportFails(
            url,
            with: .dimensionsTooLarge(limit: 32),
            policy: ImageImportPolicy(
                maximumFileBytes: 1_000_000, maximumDimension: 32, maximumPixelCount: 1_000_000
            )
        )
        await assertImportFails(
            url,
            with: .pixelBudgetExceeded(limitPixels: 1_000),
            policy: ImageImportPolicy(
                maximumFileBytes: 1_000_000, maximumDimension: 1_000, maximumPixelCount: 1_000
            )
        )
        await assertImportFails(
            url,
            with: .fileTooLarge(limitBytes: 16),
            policy: ImageImportPolicy(
                maximumFileBytes: 16, maximumDimension: 1_000, maximumPixelCount: 1_000_000
            )
        )

        // A header claiming a huge image is rejected from the header alone.
        let bomb = try directory.write(Self.pngHeader(width: 100_000, height: 100_000), named: "bomb.png")
        do {
            _ = try await ImageIOImageImporter().importImage(from: bomb)
            XCTFail("Oversized header was accepted")
        } catch let error as ImageImportError {
            XCTAssertTrue(
                [.dimensionsTooLarge(limit: 16_384), .unsupportedType].contains(error), "\(error)"
            )
        }
    }

    func testStandardPolicyBoundsDecodedMemory() {
        let policy = ImageImportPolicy.standard
        XCTAssertEqual(policy.maximumDecodedBytes, 256 * 1_024 * 1_024)
        XCTAssertLessThanOrEqual(policy.maximumFileBytes, 64 * 1_024 * 1_024)
    }

    // MARK: - File access and privacy

    func testSecurityScopedAccessIsAlwaysReleased() async throws {
        let spy = SecurityScopeSpy()
        let importer = ImageIOImageImporter(securityScope: spy)
        let valid = try directory.write(
            try TestImageFactory.encode(
                TestImageFactory.makeImage(blocks: [[.red]]),
                as: SupportedImageFormat.png.typeIdentifier
            ),
            named: "valid.png"
        )
        let corrupt = try directory.write(Data("junk".utf8), named: "corrupt.png")

        _ = try await importer.importImage(from: valid)
        XCTAssertEqual(spy.beginCount, 1)
        XCTAssertEqual(spy.endCount, 1)

        _ = try? await importer.importImage(from: corrupt)
        _ = try? await importer.importImage(from: directory.url.appendingPathComponent("gone.png"))
        XCTAssertEqual(spy.beginCount, 3)
        XCTAssertEqual(spy.endCount, 3, "Access must be released on every failure path")
    }

    func testImportWritesNothingAndRetainsNoFileMetadata() async throws {
        let data = try TestImageFactory.encode(
            TestImageFactory.makeImage(blocks: [[.red, .green]]),
            as: SupportedImageFormat.jpeg.typeIdentifier,
            orientation: 6
        )
        let url = try directory.write(data, named: "Secret Project screenshot.jpg")
        let before = try FileManager.default.contentsOfDirectory(atPath: directory.url.path)
        let temporaryBefore = try temporaryItems()

        let imported = try await ImageIOImageImporter().importImage(from: url)

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.url.path), before)
        XCTAssertEqual(try temporaryItems(), temporaryBefore)
        // Only the tightly packed raster survives: no encoded bytes, EXIF, or file location.
        let layout = try XCTUnwrap(imported.pixels.layout)
        XCTAssertEqual(imported.pixels.bytes.count, layout.byteCount)
        XCTAssertNotEqual(imported.pixels.bytes, data)
        let description = String(reflecting: imported) + String(reflecting: imported.pixels)
        XCTAssertFalse(description.contains("Secret Project"))
        XCTAssertFalse(description.contains(directory.url.path))
    }

    func testImportErrorsNeverContainPathsOrNames() {
        let errors: [ImageImportError] = [
            .notAFile, .multipleItems, .unreadable, .emptyFile, .fileTooLarge(limitBytes: 1_024),
            .unsupportedType, .corruptImage, .zeroSizedImage, .dimensionsTooLarge(limit: 10),
            .pixelBudgetExceeded(limitPixels: 10_000_000),
        ]
        for error in errors {
            XCTAssertFalse(error.userMessage.isEmpty)
            XCTAssertFalse(error.userMessage.contains("/"), error.description)
        }
    }

    // MARK: - Helpers

    private func assertImportFails(
        _ url: URL,
        with expected: ImageImportError,
        policy: ImageImportPolicy = .standard,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await ImageIOImageImporter(policy: policy).importImage(from: url)
            XCTFail("Import unexpectedly succeeded", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? ImageImportError, expected, file: file, line: line)
        }
    }

    private func temporaryItems() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(
            atPath: FileManager.default.temporaryDirectory.path
        )).filter { !$0.hasPrefix("RedScreenImportTests-") }
    }

    /// A PNG signature and IHDR chunk declaring the given size, with no image data.
    private static func pngHeader(width: UInt32, height: UInt32) -> Data {
        var ihdr = Data("IHDR".utf8)
        ihdr.append(contentsOf: withUnsafeBytes(of: width.bigEndian, Array.init))
        ihdr.append(contentsOf: withUnsafeBytes(of: height.bigEndian, Array.init))
        ihdr.append(contentsOf: [8, 6, 0, 0, 0])
        var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        data.append(contentsOf: withUnsafeBytes(of: UInt32(13).bigEndian, Array.init))
        data.append(ihdr)
        data.append(contentsOf: withUnsafeBytes(of: crc32(ihdr).bigEndian, Array.init))
        var iend = Data("IEND".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(0).bigEndian, Array.init))
        data.append(iend)
        data.append(contentsOf: withUnsafeBytes(of: crc32(iend).bigEndian, Array.init))
        iend.removeAll()
        return data
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return ~crc
    }
}
