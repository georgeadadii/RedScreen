import Foundation
import XCTest

@testable import RedScreenCore

/// Pixel-level coverage of composed candidates on the synthetic corpus (issue #8).
///
/// For every fixture, the rendered image is decoded and each pixel inside a ground-truth text box
/// is classified as ink or background (relative to that box's dominant colour). Then:
/// - **Secret coverage**: every ink pixel inside a sensitive span must be covered by a candidate.
/// - **Unrelated obscured**: share of ink outside sensitive and ambiguous spans that candidates
///   cover. This measures how much labels and benign text are hidden.
///
/// Run on ground-truth text (isolating composition) and on Vision OCR (end to end).
final class CandidateCoverageEvaluationTests: XCTestCase {
    static let minimumSecretInkCoverage = 1.0
    static let maximumUnrelatedObscuredGroundTruth = 0.05
    static let maximumUnrelatedObscuredVision = 0.08

    struct Tally {
        var secretInk = 0
        var secretInkCovered = 0
        var unrelatedInk = 0
        var unrelatedInkCovered = 0
        var uncovered: [String] = []
        var worstUnrelated: [(String, Double)] = []
        var geometry: [CandidateGeometry: Int] = [:]

        var secretCoverage: Double { secretInk == 0 ? 1 : Double(secretInkCovered) / Double(secretInk) }
        var unrelatedObscured: Double {
            unrelatedInk == 0 ? 0 : Double(unrelatedInkCovered) / Double(unrelatedInk)
        }

        var summary: String {
            String(format: "secret ink covered %d/%d (%.4f), unrelated ink obscured %d/%d (%.4f)",
                   secretInkCovered, secretInk, secretCoverage, unrelatedInkCovered, unrelatedInk,
                   unrelatedObscured)
                + "\n  geometry: \(geometry.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" })"
                + "\n  uncovered secret spans: \(uncovered)"
                + "\n  most over-redacted fixtures: "
                + worstUnrelated.sorted { $0.1 > $1.1 }.prefix(4)
                    .map { "\($0.0) \(String(format: "%.3f", $0.1))" }.joined(separator: ", ")
        }
    }

    func testGroundTruthTextCandidatesCoverSecretsAndSpareLabels() async throws {
        let tally = try await evaluate { fixture, _ in
            try fixture.groundTruth.textBoxes.map { box in
                OCRObservation(
                    text: box.text,
                    boundingBox: try box.rect.normalizedRect(),
                    boundingBoxOrigin: .topLeft,
                    confidence: try Confidence(1)
                )
            }
        }
        print("Candidates on ground-truth text: \(tally.summary)")
        XCTAssertGreaterThanOrEqual(tally.secretCoverage, Self.minimumSecretInkCoverage, tally.summary)
        XCTAssertLessThanOrEqual(tally.unrelatedObscured, Self.maximumUnrelatedObscuredGroundTruth, tally.summary)
    }

    func testVisionOCRCandidatesCoverSecretsAndSpareLabels() async throws {
        let tally = try await evaluate { _, imported in
            try await VisionTextRecognizer()
                .recognizeText(in: imported.pixels, dimensions: imported.pixelDimensions)
        }
        print("Candidates on Vision OCR: \(tally.summary)")
        XCTAssertGreaterThanOrEqual(tally.secretCoverage, Self.minimumSecretInkCoverage, tally.summary)
        XCTAssertLessThanOrEqual(tally.unrelatedObscured, Self.maximumUnrelatedObscuredVision, tally.summary)
    }

    // MARK: - Evaluation

    private func evaluate(
        observations makeObservations: (LoadedFixture, ImportedImage) async throws -> [OCRObservation]
    ) async throws -> Tally {
        var tally = Tally()
        for fixture in try FixtureLibrary.bundled().fixtures() {
            let truth = fixture.groundTruth
            let imported = try await ImageIOImageImporter().importImage(from: fixture.imageURL)
            let dimensions = imported.pixelDimensions
            let observations = try await makeObservations(fixture, imported)
            let detections = ContextualSecretDetector().detect(in: observations)
            let candidates = try GeometricCandidateComposer()
                .composeCandidates(from: detections, observations: observations, dimensions: dimensions)
            for candidate in candidates { tally.geometry[candidate.geometry, default: 0] += 1 }
            let covers = candidates.flatMap { $0.regions.map { try? $0.rect.enclosingPixelRect(in: dimensions) } }
                .compactMap { $0 }
            func covered(_ x: Int, _ y: Int) -> Bool {
                covers.contains { x >= $0.x && x < $0.x + $0.width && y >= $0.y && y < $0.y + $0.height }
            }

            let protected = try truth.spans.filter { $0.expectation != .benign }.flatMap { span in
                try span.segments.map {
                    try $0.rect.imageRect(in: dimensions).enclosingPixelRect(in: dimensions)
                }
            }
            var fixtureUnrelated = 0
            var fixtureUnrelatedCovered = 0

            for span in truth.spans where span.expectation == .sensitive {
                var ink = 0
                var hit = 0
                for segment in span.segments {
                    let rect = try segment.rect.imageRect(in: dimensions).enclosingPixelRect(in: dimensions)
                    let background = dominantColor(in: rect, pixels: imported.pixels)
                    for y in rect.y..<(rect.y + rect.height) {
                        for x in rect.x..<(rect.x + rect.width)
                        where isInk(imported.pixels.pixel(x: x, y: y), background) {
                            ink += 1
                            if covered(x, y) { hit += 1 }
                        }
                    }
                }
                tally.secretInk += ink
                tally.secretInkCovered += hit
                if hit < ink { tally.uncovered.append("\(truth.id)/\(span.id) \(ink - hit)px") }
            }

            for box in truth.textBoxes {
                let rect = try box.rect.imageRect(in: dimensions).enclosingPixelRect(in: dimensions)
                let background = dominantColor(in: rect, pixels: imported.pixels)
                for y in rect.y..<(rect.y + rect.height) {
                    for x in rect.x..<(rect.x + rect.width)
                    where isInk(imported.pixels.pixel(x: x, y: y), background) {
                        // Ink next to a protected span (within 2 px) counts as part of it.
                        if protected.contains(where: {
                            x >= $0.x - 2 && x < $0.x + $0.width + 2 && y >= $0.y - 2 && y < $0.y + $0.height + 2
                        }) { continue }
                        fixtureUnrelated += 1
                        if covered(x, y) { fixtureUnrelatedCovered += 1 }
                    }
                }
            }
            tally.unrelatedInk += fixtureUnrelated
            tally.unrelatedInkCovered += fixtureUnrelatedCovered
            if fixtureUnrelated > 0 {
                tally.worstUnrelated.append((truth.id, Double(fixtureUnrelatedCovered) / Double(fixtureUnrelated)))
            }
        }
        return tally
    }

    private func dominantColor(in rect: PixelRect, pixels: DecodedPixels) -> TestImageFactory.RGBA {
        var counts: [UInt32: Int] = [:]
        for y in stride(from: rect.y, to: rect.y + rect.height, by: 1) {
            for x in stride(from: rect.x, to: rect.x + rect.width, by: 2) {
                let p = pixels.pixel(x: x, y: y)
                counts[UInt32(p.red) << 16 | UInt32(p.green) << 8 | UInt32(p.blue), default: 0] += 1
            }
        }
        let key = counts.max { $0.value < $1.value }?.key ?? 0
        return TestImageFactory.RGBA(
            red: UInt8(key >> 16 & 0xFF), green: UInt8(key >> 8 & 0xFF), blue: UInt8(key & 0xFF), alpha: 255
        )
    }

    private func isInk(_ pixel: TestImageFactory.RGBA, _ background: TestImageFactory.RGBA) -> Bool {
        abs(Int(pixel.red) - Int(background.red)) + abs(Int(pixel.green) - Int(background.green))
            + abs(Int(pixel.blue) - Int(background.blue)) > 60
    }
}
