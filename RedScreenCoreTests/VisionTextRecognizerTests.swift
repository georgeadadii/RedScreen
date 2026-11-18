import CoreGraphics
import Foundation
import ImageIO
import Vision
import XCTest

@testable import RedScreenCore

/// Runs real on-device Vision OCR against the synthetic fixture corpus (issue #6).
final class VisionTextRecognizerTests: XCTestCase {
    /// Minimum share of ground-truth text boxes that must be located and read in each fixture.
    static let minimumLineRecallPerFixture = 0.85
    /// Minimum share across the whole corpus.
    static let minimumLineRecallOverall = 0.95
    /// A ground-truth box is located when OCR boxes cover at least this much of it.
    static let minimumBoxCoverage = 0.8
    /// A located line is read correctly within this character error rate.
    static let maximumCharacterErrorRate = 0.1

    // MARK: - Configuration

    func testRequestUsesAccurateOnDeviceSettingsWithoutLanguageCorrection() {
        let request = VisionTextRecognizer().makeRequest()

        XCTAssertEqual(request.recognitionLevel, .accurate)
        XCTAssertFalse(request.usesLanguageCorrection)
        XCTAssertEqual(request.customWords, [])
        XCTAssertEqual(request.recognitionLanguages, ["en-US"])
        XCTAssertFalse(request.automaticallyDetectsLanguage)
    }

    // MARK: - Corpus accuracy

    func testRecognizesTheSyntheticCorpusWithinTolerances() async throws {
        var report: [String] = []
        var located = 0
        var total = 0

        for fixture in try FixtureLibrary.bundled().fixtures() {
            let truth = fixture.groundTruth
            let imported = try await ImageIOImageImporter().importImage(from: fixture.imageURL)
            let observations = try await VisionTextRecognizer()
                .recognizeText(in: imported.pixels, dimensions: imported.pixelDimensions)
            try assertWellFormed(observations, dimensions: imported.pixelDimensions, id: fixture.id)

            let score = try Self.score(observations, against: truth)
            located += score.found
            total += score.total
            report.append(
                "\(fixture.id): \(score.found)/\(score.total) lines"
                    + (score.missedBoxIDs.isEmpty ? "" : " missed \(score.missedBoxIDs)")
            )
            XCTAssertGreaterThanOrEqual(
                Double(score.found) / Double(score.total), Self.minimumLineRecallPerFixture,
                "\(fixture.id) missed \(score.missedBoxIDs)"
            )
        }

        let overall = Double(located) / Double(total)
        // Report text box IDs and counts only, never recognized text.
        print("OCR corpus recall \(located)/\(total) = \(String(format: "%.3f", overall))\n"
            + report.joined(separator: "\n"))
        XCTAssertGreaterThanOrEqual(overall, Self.minimumLineRecallOverall)
    }

    func testOrientationAndCoordinatesAreCorrectForEverySupportedFormat() async throws {
        let directory = try TemporaryTestDirectory()
        let fixture = try FixtureLibrary.bundled().fixture(id: "env-file-light-2x")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(fixture.imageURL as CFURL, nil))
        let upright = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))

        // Same upright content delivered as PNG, JPEG, HEIC, and as a JPEG whose pixels are
        // stored rotated with EXIF orientation 6 (display = stored rotated 90° clockwise).
        let variants: [(String, Data)] = [
            ("png", try TestImageFactory.encode(upright, as: "public.png")),
            ("jpeg", try TestImageFactory.encode(upright, as: "public.jpeg")),
            ("heic", try TestImageFactory.encode(upright, as: "public.heic")),
            ("rotated.jpeg", try TestImageFactory.encode(
                Self.rotatedCounterClockwise(upright), as: "public.jpeg", orientation: 6
            )),
        ]
        for (name, data) in variants {
            let url = try directory.write(data, named: "variant.\(name)")
            let imported = try await ImageIOImageImporter().importImage(from: url)
            XCTAssertEqual(imported.pixelDimensions, try fixture.groundTruth.pixelDimensions(), name)

            let observations = try await VisionTextRecognizer()
                .recognizeText(in: imported.pixels, dimensions: imported.pixelDimensions)
            try assertWellFormed(observations, dimensions: imported.pixelDimensions, id: name)
            let score = try Self.score(observations, against: fixture.groundTruth)
            XCTAssertEqual(score.found, score.total, "\(name) missed \(score.missedBoxIDs)")
        }
    }

    func testWordSegmentsLocateSensitiveValuesWithinTheirLine() async throws {
        let fixture = try FixtureLibrary.bundled().fixture(id: "env-diff-columns-light-2x")
        let imported = try await ImageIOImageImporter().importImage(from: fixture.imageURL)
        let dimensions = imported.pixelDimensions
        let observations = try await VisionTextRecognizer()
            .recognizeText(in: imported.pixels, dimensions: dimensions)

        // Every sensitive segment is covered by some word segment's box. Vision reports
        // word-level boxes, so `KEY=value` without spaces is one segment that covers both.
        let words = try observations.flatMap { observation in
            try observation.segments.map {
                try observation.imageRect(for: $0, in: dimensions)
                    .normalized(in: dimensions, targetOrigin: .topLeft)
            }
        }
        XCTAssertFalse(words.isEmpty)
        for span in fixture.groundTruth.spans where span.expectation == .sensitive {
            for segment in span.segments {
                let coverage = FixtureGeometry.coverageFraction(
                    of: try segment.rect.normalizedRect(), by: words
                )
                XCTAssertGreaterThan(coverage, Self.minimumBoxCoverage, span.id)
            }
        }
    }

    func testRefinementRetainsSmallTextAndDoesNotConfuseColumnsOrDuplicateLines() throws {
        func line(_ text: String, x: Double, width: Double, confidence: Double = 1) throws -> OCRObservation {
            OCRObservation(text: text, boundingBox: try NormalizedRect(x: x, y: 0.2, width: width, height: 0.05),
                           boundingBoxOrigin: .bottomLeft, confidence: try Confidence(confidence))
        }
        let left = try line("---BEGIN SYNTHETIC---", x: 0.05, width: 0.35)
        let right = try line("small synthetic text", x: 0.6, width: 0.3)
        let corrected = try line("-----BEGIN SYNTHETIC-----", x: 0.05, width: 0.35)
        let unrelated = try line("longer unrelated text in another column", x: 0.45, width: 0.1)
        let refined = VisionTextRecognizer.refining([left, right], with: [corrected, unrelated])
        XCTAssertEqual(refined, [corrected, right])
        let duplicates = VisionTextRecognizer.refining([left, left], with: [corrected])
        XCTAssertEqual(duplicates, [corrected, left])
        let lowConfidence = try line("-----BEGIN SYNTHETIC-----", x: 0.05, width: 0.35, confidence: 0.5)
        XCTAssertEqual(VisionTextRecognizer.refining([left], with: [lowConfidence]), [left])
        let wrongLetters = try line("-----BEGIN DIFFERENT SYNTHETIC-----", x: 0.05, width: 0.35)
        XCTAssertEqual(VisionTextRecognizer.refining([left], with: [wrongLetters]), [left])
        let assignment = try line("DEMO_KEY=RSFAKE123", x: 0.05, width: 0.35)
        let wrongSyntax = try line("DEMO_KEY---RSFAKE123", x: 0.05, width: 0.35)
        XCTAssertEqual(VisionTextRecognizer.refining([assignment], with: [wrongSyntax]), [assignment])
    }

    func testLargeTextRefinementRecognizesPEMHeadersWithoutChangingSourcePixels() async throws {
        let fixture = try FixtureLibrary.bundled().fixture(id: "private-key-block-light-2x")
        let imported = try await ImageIOImageImporter().importImage(from: fixture.imageURL)
        let original = imported.pixels.bytes
        let observations = try await VisionTextRecognizer().recognizeText(in: imported.pixels, dimensions: imported.pixelDimensions)
        let score = try Self.score(observations, against: fixture.groundTruth)
        XCTAssertEqual(score.found, score.total)
        try assertWellFormed(observations, dimensions: imported.pixelDimensions, id: fixture.id)
        XCTAssertEqual(imported.pixels.bytes, original)
    }

    // MARK: - Behaviour

    func testRejectsPixelsWithoutLayoutOrWithMismatchedDimensions() async throws {
        let dimensions = try PixelDimensions(width: 2, height: 2)
        do {
            _ = try await VisionTextRecognizer()
                .recognizeText(in: DecodedPixels(bytes: Data(count: 16)), dimensions: dimensions)
            XCTFail("Accepted pixels without a layout")
        } catch {
            XCTAssertEqual(error as? TextRecognitionError, .invalidImage)
        }

        let layout = PixelBufferLayout(dimensions: dimensions, colorSpace: .sRGB)
        do {
            _ = try await VisionTextRecognizer().recognizeText(
                in: DecodedPixels(bytes: Data(count: 16), layout: layout),
                dimensions: try PixelDimensions(width: 4, height: 1)
            )
            XCTFail("Accepted mismatched dimensions")
        } catch {
            XCTAssertEqual(error as? TextRecognitionError, .invalidImage)
        }
    }

    func testBlankImageProducesNoObservations() async throws {
        let image = TestImageFactory.makeImage(blocks: [[.white]], blockSize: 64)
        let directory = try TemporaryTestDirectory()
        let url = try directory.write(try TestImageFactory.encode(image, as: "public.png"), named: "blank.png")
        let imported = try await ImageIOImageImporter().importImage(from: url)

        let observations = try await VisionTextRecognizer()
            .recognizeText(in: imported.pixels, dimensions: imported.pixelDimensions)

        XCTAssertEqual(observations, [])
    }

    func testCancellationStopsRecognition() async throws {
        let imported = try await largestFixture()
        let task = Task {
            try await VisionTextRecognizer()
                .recognizeText(in: imported.pixels, dimensions: imported.pixelDimensions)
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled recognition returned a result")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    func testRecognitionWritesNothingToDisk() async throws {
        let imported = try await largestFixture()
        let temporary = FileManager.default.temporaryDirectory
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: temporary.path))

        _ = try await VisionTextRecognizer()
            .recognizeText(in: imported.pixels, dimensions: imported.pixelDimensions)

        let after = Set(try FileManager.default.contentsOfDirectory(atPath: temporary.path))
        XCTAssertEqual(after.subtracting(before).filter { !$0.hasPrefix("RedScreen") }, [])
    }

    func testRecognizerSourceHasNoNetworkingOrPersistence() throws {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("RedScreenCore/Platform/VisionTextRecognizer.swift")
        let source = try String(contentsOf: path, encoding: .utf8)
        for forbidden in [
            "URLSession", "URLRequest", "Network", "UserDefaults", "FileManager",
            ".write(", "print(", "Logger(", "NSLog",
        ] {
            XCTAssertFalse(source.contains(forbidden), "Recognizer must not use \(forbidden)")
        }
    }

    // MARK: - Performance

    func testRecognitionPerformanceSmallScreenshot() throws {
        try measureRecognition(of: "benign-terminal-dark-1x")
    }

    func testRecognitionPerformanceLargeScreenshot() throws {
        try measureRecognition(of: "dashboard-api-keys-dark-2x")
    }

    private func measureRecognition(of id: String) throws {
        let url = try FixtureLibrary.bundled().fixture(id: id).imageURL
        let importer = ImageIOImageImporter()
        let box = ImportedBox()
        let loaded = expectation(description: "import")
        Task {
            box.value = try? await importer.importImage(from: url)
            loaded.fulfill()
        }
        wait(for: [loaded], timeout: 10)
        let imported = try XCTUnwrap(box.value)

        // Records timing only; secret content is never asserted here.
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            let done = expectation(description: "recognize")
            Task {
                _ = try? await VisionTextRecognizer()
                    .recognizeText(in: imported.pixels, dimensions: imported.pixelDimensions)
                done.fulfill()
            }
            wait(for: [done], timeout: 30)
        }
    }

    // MARK: - Scoring

    struct Score {
        let found: Int
        let total: Int
        let missedBoxIDs: [String]
    }

    /// A ground-truth line counts as found when OCR lines that overlap it vertically (by at least
    /// half the smaller height) cover enough of its horizontal extent, and their text contains
    /// it within the character error tolerance. Vision's boxes hug the ink while ground-truth
    /// boxes span the font's full ascent and descent, so a 2D area ratio would be misleading.
    ///
    /// Boxes with fewer than two visible characters (a lone `{`, `}`, or `0`) are not scored:
    /// Vision does not report isolated single glyphs, and they cannot hold a secret.
    static func score(_ observations: [OCRObservation], against truth: FixtureGroundTruth) throws
        -> Score {
        let dimensions = try truth.pixelDimensions()
        let boxes = try observations.map {
            try $0.imageRect(in: dimensions).normalized(in: dimensions, targetOrigin: .topLeft)
        }
        let scored = truth.textBoxes.filter { $0.text.filter { !$0.isWhitespace }.count >= 2 }
        var missed: [String] = []
        for box in scored {
            let target = try box.rect.normalizedRect()
            let overlapping = zip(observations, boxes).filter { _, rect in
                let verticalOverlap = min(rect.y + rect.height, target.y + target.height)
                    - max(rect.y, target.y)
                let horizontalOverlap = min(rect.x + rect.width, target.x + target.width)
                    - max(rect.x, target.x)
                return horizontalOverlap > 0
                    && verticalOverlap >= 0.5 * min(rect.height, target.height)
            }
            let coverage = horizontalCoverage(
                of: target, by: overlapping.map(\.1)
            )
            let recognized = overlapping.sorted { $0.1.x < $1.1.x }.map(\.0.text)
                .joined(separator: " ")
            let errorRate = approximateSubstringErrorRate(of: box.text, in: recognized)
            if coverage < minimumBoxCoverage || errorRate > maximumCharacterErrorRate {
                missed.append(box.id)
            }
        }
        return Score(
            found: scored.count - missed.count,
            total: scored.count,
            missedBoxIDs: missed
        )
    }

    static func horizontalCoverage(
        of target: RedScreenCore.NormalizedRect,
        by rects: [RedScreenCore.NormalizedRect]
    ) -> Double {
        let intervals = rects.map {
            (max($0.x, target.x), min($0.x + $0.width, target.x + target.width))
        }.filter { $0.0 < $0.1 }.sorted { $0.0 < $1.0 }
        var covered = 0.0
        var end = target.x
        for (start, stop) in intervals where stop > end {
            covered += stop - max(start, end)
            end = stop
        }
        return covered / target.width
    }

    /// Edit distance from `needle` to its best-matching substring of `haystack`, divided by the
    /// needle length. Whitespace is ignored because OCR spacing is not part of the content.
    static func approximateSubstringErrorRate(of needle: String, in haystack: String) -> Double {
        let pattern = Array(needle.filter { !$0.isWhitespace })
        let text = Array(haystack.filter { !$0.isWhitespace })
        guard !pattern.isEmpty else { return 0 }
        var previous = Array(0...pattern.count)
        var best = previous[pattern.count]
        for character in text {
            var current = [0] + Array(repeating: 0, count: pattern.count)
            for index in 1...pattern.count {
                let substitution = previous[index - 1] + (pattern[index - 1] == character ? 0 : 1)
                current[index] = min(substitution, previous[index] + 1, current[index - 1] + 1)
            }
            best = min(best, current[pattern.count])
            previous = current
        }
        return Double(best) / Double(pattern.count)
    }

    // MARK: - Helpers

    private func assertWellFormed(
        _ observations: [OCRObservation],
        dimensions: PixelDimensions,
        id: String
    ) throws {
        XCTAssertFalse(observations.isEmpty, id)
        XCTAssertEqual(Set(observations.map(\.id)).count, observations.count, id)
        for observation in observations {
            XCTAssertEqual(observation.boundingBoxOrigin, .bottomLeft, id)
            XCTAssertFalse(observation.text.isEmpty, id)
            let rect = try observation.imageRect(in: dimensions)
            XCTAssertTrue(rect.isContained(in: dimensions), id)
            let utf16Count = observation.text.utf16.count
            for segment in observation.segments {
                XCTAssertGreaterThanOrEqual(segment.utf16Range.lowerBound, 0, id)
                XCTAssertLessThanOrEqual(segment.utf16Range.upperBound, utf16Count, id)
                XCTAssertTrue(
                    try observation.imageRect(for: segment, in: dimensions).isContained(in: dimensions),
                    id
                )
            }
        }
    }

    private func largestFixture() async throws -> ImportedImage {
        try await ImageIOImageImporter().importImage(
            from: try FixtureLibrary.bundled().fixture(id: "ci-log-dark-2x").imageURL
        )
    }

    /// Stores `image` rotated 90° counter-clockwise, so EXIF orientation 6 restores it.
    private static func rotatedCounterClockwise(_ image: CGImage) -> CGImage {
        let width = image.width
        let height = image.height
        let context = CGContext(
            data: nil, width: height, height: width, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        // In Core Graphics' bottom-left space, a +90° rotation turns the image counter-clockwise.
        context.translateBy(x: CGFloat(height), y: 0)
        context.rotate(by: .pi / 2)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }
}

private final class ImportedBox: @unchecked Sendable {
    var value: ImportedImage?
}
