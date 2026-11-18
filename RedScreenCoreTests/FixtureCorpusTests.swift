import CoreGraphics
import Foundation
import ImageIO
import XCTest

@testable import RedScreenCore

/// Self-tests for the synthetic screenshot corpus in RedScreenCoreTests/Fixtures.
final class FixtureCorpusTests: XCTestCase {
    private var library: FixtureLibrary!
    private var fixtures: [LoadedFixture]!

    override func setUpWithError() throws {
        library = try FixtureLibrary.bundled()
        fixtures = try library.fixtures()
    }

    // MARK: - Manifest and drift

    func testManifestListsEveryCorpusFileExactlyOnce() throws {
        let listed = Set(library.manifest.entries.flatMap { [$0.image, $0.groundTruth] })
            .union(["manifest.json"])
        XCTAssertEqual(
            listed.count, library.manifest.entries.count * 2 + 1,
            "Manifest entries must reference distinct files"
        )
        XCTAssertEqual(try library.allRelativeFilePaths(), listed)
        XCTAssertEqual(
            Set(library.manifest.entries.map(\.id)).count, library.manifest.entries.count
        )
        XCTAssertEqual(library.manifest.schemaVersion, FixtureSchema.version)
        XCTAssertEqual(library.manifest.notice, FixtureSchema.notice)
    }

    func testCommittedFilesMatchManifestHashes() throws {
        for fixture in fixtures {
            XCTAssertEqual(
                FixtureDigest.sha256Hex(try fixture.imageData()), fixture.entry.imageSHA256,
                "\(fixture.id) image drifted; regenerate with `make fixtures`"
            )
            XCTAssertEqual(
                FixtureDigest.sha256Hex(try library.data(atRelativePath: fixture.entry.groundTruth)),
                fixture.entry.groundTruthSHA256,
                "\(fixture.id) ground truth drifted; regenerate with `make fixtures`"
            )
        }
    }

    func testCommittedGroundTruthMatchesScenarioSpecifications() throws {
        let renderer = FixtureRenderer()
        var expectedIDs: Set<String> = []
        for scenario in FixtureScenarios.all {
            for scale in FixtureScenarios.scales {
                let expected = try renderer.groundTruth(for: scenario, scale: scale)
                expectedIDs.insert(expected.id)
                let committed = try library.fixture(id: expected.id).groundTruth
                assertEquivalent(committed, expected)
            }
        }
        XCTAssertEqual(Set(fixtures.map(\.id)), expectedIDs, "Run `make fixtures`")
    }

    func testRendererIsDeterministic() throws {
        let renderer = FixtureRenderer()
        for scenario in [FixtureScenarios.envFileLight, FixtureScenarios.dashboardAPIKeysDark] {
            let first = try renderer.render(scenario, scale: 2)
            let second = try renderer.render(scenario, scale: 2)
            XCTAssertEqual(first.png, second.png, scenario.name)
            XCTAssertEqual(first.groundTruth, second.groundTruth, scenario.name)
        }
    }

    func testRendererRejectsTextThatWouldBeClipped() {
        let scenario = FixtureScenario(
            name: "overflow",
            description: "Overflow self-test",
            category: .benignCode,
            theme: .light,
            fontStyle: .monospace,
            canvasWidth: 80,
            difficulties: [],
            blocks: [FixtureBlock(
                row: 0, x: 0, runs: [FixtureRun(text: "this line cannot fit", mark: nil)]
            )]
        )
        XCTAssertThrowsError(try FixtureRenderer().groundTruth(for: scenario, scale: 1)) {
            XCTAssertEqual($0 as? FixtureRenderError, .textOverflow(scenario: "overflow", row: 0))
        }
    }

    // MARK: - Ground-truth validity

    func testEveryFixtureHasValidInBoundsGroundTruth() throws {
        for fixture in fixtures {
            let truth = fixture.groundTruth
            let id = fixture.id
            XCTAssertEqual(truth.id, id)
            XCTAssertEqual(truth.schemaVersion, FixtureSchema.version, id)
            XCTAssertEqual(truth.coordinateSpace, FixtureSchema.coordinateSpace, id)
            XCTAssertTrue(truth.syntheticTestData, id)
            XCTAssertGreaterThanOrEqual(truth.scenario.count, 40, "\(id) needs a description")
            XCTAssertTrue(FixtureScenarios.scales.contains(truth.scale), id)
            XCTAssertTrue(id.hasSuffix("-\(truth.scale)x"), id)
            XCTAssertEqual(fixture.entry.image, "images/\(id).png")
            XCTAssertEqual(fixture.entry.groundTruth, "ground-truth/\(id).json")

            let decoded = try fixture.decodedPixelSize()
            XCTAssertEqual(decoded.width, truth.pixelWidth, id)
            XCTAssertEqual(decoded.height, truth.pixelHeight, id)
            let dimensions = try truth.pixelDimensions()

            XCTAssertFalse(truth.textBoxes.isEmpty, id)
            XCTAssertEqual(Set(truth.textBoxes.map(\.id)).count, truth.textBoxes.count, id)
            for box in truth.textBoxes {
                XCTAssertFalse(box.text.isEmpty, "\(id) \(box.id)")
                let rect = try box.rect.normalizedRect()
                XCTAssertTrue(try box.rect.imageRect(in: dimensions).isContained(in: dimensions))
                XCTAssertLessThanOrEqual(rect.x + rect.width, 1, "\(id) \(box.id)")
                XCTAssertLessThanOrEqual(rect.y + rect.height, 1, "\(id) \(box.id)")
            }

            XCTAssertEqual(Set(truth.spans.map(\.id)).count, truth.spans.count, id)
            for span in truth.spans {
                XCTAssertFalse(span.note.isEmpty, "\(id) \(span.id)")
                XCTAssertFalse(span.segments.isEmpty, "\(id) \(span.id)")
                XCTAssertNotNil(truth.text(of: span), "\(id) \(span.id) offsets out of range")
                for segment in span.segments {
                    let box = try XCTUnwrap(truth.textBox(id: segment.textBoxID))
                    let segmentRect = try segment.rect.normalizedRect()
                    let boxRect = try box.rect.normalizedRect()
                    XCTAssertGreaterThanOrEqual(segmentRect.x, boxRect.x - 2e-6, span.id)
                    XCTAssertLessThanOrEqual(
                        segmentRect.x + segmentRect.width, boxRect.x + boxRect.width + 2e-6,
                        span.id
                    )
                    XCTAssertEqual(segmentRect.y, boxRect.y, accuracy: 1e-9, span.id)
                    XCTAssertEqual(segmentRect.height, boxRect.height, accuracy: 1e-9, span.id)
                }
                XCTAssertFalse(
                    span.note.contains(truth.text(of: span) ?? "\u{0}"),
                    "\(id) \(span.id) note must not repeat its value"
                )
            }
        }
    }

    func testUnknownLabelsAreRejected() throws {
        let fixture = try XCTUnwrap(fixtures.first { !$0.groundTruth.spans.isEmpty })
        let data = try library.data(atRelativePath: fixture.entry.groundTruth)
        let family = try XCTUnwrap(fixture.groundTruth.spans.first?.family.rawValue)
        let tampered = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\"\(family)\"", with: "\"notARealFamily\"")
        XCTAssertThrowsError(
            try FixtureJSON.decoder().decode(FixtureGroundTruth.self, from: Data(tampered.utf8))
        )
    }

    func testTextBoxesContainRenderedInk() throws {
        for fixture in fixtures {
            let pixels = try RGBAImage(url: fixture.imageURL)
            let background = pixels.pixel(x: 1, y: 1)
            let dimensions = try fixture.groundTruth.pixelDimensions()
            for box in fixture.groundTruth.textBoxes {
                let rect = try box.rect.imageRect(in: dimensions).enclosingPixelRect(in: dimensions)
                var inkPixels = 0
                for y in rect.y..<(rect.y + rect.height) {
                    for x in rect.x..<(rect.x + rect.width) where
                        pixels.pixel(x: x, y: y).distance(to: background) > 24 {
                        inkPixels += 1
                    }
                }
                XCTAssertGreaterThan(
                    inkPixels, rect.width * rect.height / 50,
                    "\(fixture.id) \(box.id) has no visible text inside its ground-truth box"
                )
            }
        }
    }

    // MARK: - Coverage

    func testEveryDetectorFamilyHasPositiveNegativeAndAmbiguousCases() {
        let spans = fixtures.flatMap(\.groundTruth.spans)
        for family in FixtureSecretFamily.allCases {
            for expectation in FixtureExpectation.allCases {
                XCTAssertTrue(
                    spans.contains { $0.family == family && $0.expectation == expectation },
                    "No \(expectation.rawValue) example for \(family.rawValue)"
                )
            }
        }
    }

    func testCorpusCoversRequiredScenarioDimensions() {
        let truths = fixtures.map(\.groundTruth)
        XCTAssertEqual(Set(truths.map(\.category)), Set(FixtureCategory.allCases))
        XCTAssertEqual(Set(truths.map(\.theme)), Set(FixtureTheme.allCases))
        XCTAssertEqual(Set(truths.map(\.fontStyle)), Set(FixtureFontStyle.allCases))
        XCTAssertEqual(Set(truths.flatMap(\.difficulties)), Set(FixtureDifficulty.allCases))
        XCTAssertEqual(Set(truths.map(\.scale)), Set(FixtureScenarios.scales))

        let wrapped = truths.flatMap(\.spans).filter {
            Set($0.segments.map(\.textBoxID)).count > 1
        }
        XCTAssertTrue(wrapped.contains { $0.expectation == .sensitive })
        XCTAssertTrue(truths.contains { truth in
            truth.spans.isEmpty == false && truth.spans.allSatisfy { $0.expectation == .benign }
        }, "Corpus needs at least one fixture with no redaction targets")

        for scenario in FixtureScenarios.all {
            for scale in FixtureScenarios.scales {
                XCTAssertTrue(
                    truths.contains { $0.id == "\(scenario.name)-\(scale)x" },
                    "\(scenario.name) is missing its \(scale)x rendering"
                )
            }
        }
    }

    func testScaleVariantsShareNormalizedGeometry() throws {
        for scenario in FixtureScenarios.all {
            let oneX = try library.fixture(id: "\(scenario.name)-1x").groundTruth
            let twoX = try library.fixture(id: "\(scenario.name)-2x").groundTruth
            XCTAssertEqual(twoX.pixelWidth, oneX.pixelWidth * 2, scenario.name)
            XCTAssertEqual(twoX.pixelHeight, oneX.pixelHeight * 2, scenario.name)
            XCTAssertEqual(twoX.textBoxes, oneX.textBoxes, scenario.name)
            XCTAssertEqual(twoX.spans, oneX.spans, scenario.name)
        }
    }

    // MARK: - Helpers

    private func assertEquivalent(
        _ committed: FixtureGroundTruth,
        _ expected: FixtureGroundTruth,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let id = expected.id
        XCTAssertEqual(committed.scenario, expected.scenario, id, file: file, line: line)
        XCTAssertEqual(committed.category, expected.category, id, file: file, line: line)
        XCTAssertEqual(committed.theme, expected.theme, id, file: file, line: line)
        XCTAssertEqual(committed.fontStyle, expected.fontStyle, id, file: file, line: line)
        XCTAssertEqual(committed.difficulties, expected.difficulties, id, file: file, line: line)
        XCTAssertEqual(committed.pixelWidth, expected.pixelWidth, id, file: file, line: line)
        XCTAssertEqual(committed.pixelHeight, expected.pixelHeight, id, file: file, line: line)
        XCTAssertEqual(
            committed.textBoxes.map(\.text), expected.textBoxes.map(\.text), id,
            file: file, line: line
        )
        XCTAssertEqual(
            committed.spans.map { [$0.id, $0.family.rawValue, $0.expectation.rawValue, $0.note] },
            expected.spans.map { [$0.id, $0.family.rawValue, $0.expectation.rawValue, $0.note] },
            id, file: file, line: line
        )
        // Font rasterisation may differ slightly between macOS releases, so geometry is compared
        // with a tolerance while text and labels must match exactly.
        let tolerance = 0.003
        for (lhs, rhs) in zip(committed.textBoxes, expected.textBoxes) {
            assertClose(lhs.rect, rhs.rect, tolerance, "\(id) \(lhs.id)", file: file, line: line)
        }
        for (lhs, rhs) in zip(committed.spans, expected.spans) {
            XCTAssertEqual(lhs.segments.count, rhs.segments.count, file: file, line: line)
            for (left, right) in zip(lhs.segments, rhs.segments) {
                XCTAssertEqual(left.textBoxID, right.textBoxID, file: file, line: line)
                XCTAssertEqual(left.utf16Offset, right.utf16Offset, file: file, line: line)
                XCTAssertEqual(left.utf16Length, right.utf16Length, file: file, line: line)
                assertClose(left.rect, right.rect, tolerance, "\(id) \(lhs.id)", file: file, line: line)
            }
        }
    }

    private func assertClose(
        _ lhs: FixtureRect,
        _ rhs: FixtureRect,
        _ tolerance: Double,
        _ message: String,
        file: StaticString,
        line: UInt
    ) {
        XCTAssertEqual(lhs.x, rhs.x, accuracy: tolerance, message, file: file, line: line)
        XCTAssertEqual(lhs.y, rhs.y, accuracy: tolerance, message, file: file, line: line)
        XCTAssertEqual(lhs.width, rhs.width, accuracy: tolerance, message, file: file, line: line)
        XCTAssertEqual(lhs.height, rhs.height, accuracy: tolerance, message, file: file, line: line)
    }
}

/// Minimal RGBA8 decoder for ink checks. Test-only; buffers are released with the value.
private struct RGBAImage {
    struct Pixel {
        let red: Int
        let green: Int
        let blue: Int

        func distance(to other: Pixel) -> Int {
            abs(red - other.red) + abs(green - other.green) + abs(blue - other.blue)
        }
    }

    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init(url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw FixtureLibrary.LoadError.imageUndecodable(url.lastPathComponent)
        }
        let width = image.width
        let height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = buffer.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else {
            throw FixtureLibrary.LoadError.imageUndecodable(url.lastPathComponent)
        }
        self.width = width
        self.height = height
        bytes = buffer
    }

    /// Pixel at a top-left-origin coordinate.
    func pixel(x: Int, y: Int) -> Pixel {
        let offset = (y * width + x) * 4
        return Pixel(red: Int(bytes[offset]), green: Int(bytes[offset + 1]), blue: Int(bytes[offset + 2]))
    }
}
