import Foundation
import XCTest

@testable import RedScreenCore

final class SolidFillRedactionRendererTests: XCTestCase {
    func testFractionalOverlappingAndEdgeFillsMatchWholeRasterAtBothScales() async throws {
        for scale in [1, 2] {
            let dimensions = try PixelDimensions(width: 8 * scale, height: 6 * scale)
            let source = pixels(dimensions, colorSpace: .sRGB)
            let original = source.bytes
            func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) throws -> ImageRect {
                try ImageRect(x: x * Double(scale), y: y * Double(scale),
                              width: w * Double(scale), height: h * Double(scale))
            }
            let document = try document(dimensions, manual: [
                rect(1.25, 1.25, 2.5, 2.5), rect(3, 2, 2, 2),
                rect(7.5, 0, 0.5, 6), rect(0, 5.5, 8, 0.5), rect(0, 0, 0.25, 0.25),
            ])
            let result = try await SolidFillRedactionRenderer().render(document: document, sourceImage: source)
            var expected = original
            // Independent integer coverage oracle for these particular rectangles. Whole-raster
            // equality samples every interior, all four edges, and the unchanged padded boundary.
            for y in 0..<dimensions.height {
                for x in 0..<dimensions.width {
                    let first = x >= scale && x < 4 * scale && y >= scale && y < 4 * scale
                    let overlap = x >= 3 * scale && x < 5 * scale && y >= 2 * scale && y < 4 * scale
                    let right = x >= (scale == 1 ? 7 : 15)
                    let bottom = y >= (scale == 1 ? 5 : 11)
                    if first || overlap || right || bottom || (x == 0 && y == 0) {
                        let i = (y * dimensions.width + x) * 4
                        expected.replaceSubrange(i..<i + 4, with: [0, 0, 0, 255])
                    }
                }
            }
            XCTAssertEqual(result.bytes, expected)
            XCTAssertEqual(result.layout, source.layout)
            XCTAssertEqual(source.bytes, original)
            XCTAssertFalse(result === source)
        }
    }

    func testCustomColorReplacesHiddenRGBAndAlphaExactlyInBothColorSpaces() async throws {
        for space in [RenderingColorSpace.sRGB, .displayP3] {
            let dimensions = try PixelDimensions(width: 3, height: 2)
            // Includes nonzero hidden RGB at zero alpha to prove all four bytes are overwritten.
            let bytes = Data([11, 22, 33, 0, 10, 20, 30, 128, 1, 2, 3, 255,
                              11, 22, 33, 0, 10, 20, 30, 128, 1, 2, 3, 255])
            let source = DecodedPixels(bytes: bytes, layout: PixelBufferLayout(dimensions: dimensions, colorSpace: space))
            let document = try document(dimensions, manual: [ImageRect(x: 0, y: 0, width: 2, height: 2)])
            let renderer = SolidFillRedactionRenderer(fillColor: RedactionFillColor(red: 19, green: 103, blue: 241))
            let result = try await renderer.render(document: document, sourceImage: source)
            XCTAssertEqual(result.bytes, Data([19, 103, 241, 255, 19, 103, 241, 255, 1, 2, 3, 255,
                                               19, 103, 241, 255, 19, 103, 241, 255, 1, 2, 3, 255]))
            XCTAssertEqual(result.layout, source.layout)
            XCTAssertEqual(source.bytes, bytes)
        }
    }

    func testIncludedAndManualMatchWhilePendingAndExcludedPreserveSource() async throws {
        let dimensions = try PixelDimensions(width: 8, height: 6)
        let source = pixels(dimensions, colorSpace: .sRGB)
        let rect = try ImageRect(x: 1.2, y: 2.1, width: 3.4, height: 1.8)
        let observation = OCRObservation(text: "synthetic", boundingBox: try NormalizedRect(x: 0, y: 0, width: 1, height: 1),
                                         boundingBoxOrigin: .topLeft, confidence: try Confidence(1))
        let evidence = try DetectionEvidence(ruleID: DetectorRuleID("test.render"), observationIDs: [observation.id], confidence: Confidence(1))
        let renderer = SolidFillRedactionRenderer()
        let manual = try await renderer.render(document: document(dimensions, manual: [rect]), sourceImage: source)
        for disposition in [RedactionDisposition.included, .pending, .excluded] {
            let candidate = try RedactionCandidate(region: RedactionRegion(rect: rect), evidence: evidence, disposition: disposition)
            let document = try RedactionDocument(sourceIdentity: SourceImageIdentity(), pixelDimensions: dimensions,
                                                observations: [observation], candidates: [candidate])
            let result = try await renderer.render(document: document, sourceImage: source)
            XCTAssertEqual(result.bytes, disposition == .included ? manual.bytes : source.bytes)
        }
    }

    func testEveryRegionOfIncludedCandidateIsRendered() async throws {
        let dimensions = try PixelDimensions(width: 3, height: 1)
        let observation = OCRObservation(text: "synthetic", boundingBox: try NormalizedRect(x: 0, y: 0, width: 1, height: 1),
                                         boundingBoxOrigin: .topLeft, confidence: try Confidence(1))
        let candidate = try RedactionCandidate(regions: [
            RedactionRegion(rect: ImageRect(x: 0, y: 0, width: 1, height: 1)),
            RedactionRegion(rect: ImageRect(x: 2, y: 0, width: 1, height: 1)),
        ], evidence: [DetectionEvidence(ruleID: DetectorRuleID("test.render"), observationIDs: [observation.id], confidence: Confidence(1))], disposition: .included)
        let document = try RedactionDocument(sourceIdentity: SourceImageIdentity(), pixelDimensions: dimensions,
                                            observations: [observation], candidates: [candidate])
        let source = pixels(dimensions, colorSpace: .sRGB)
        let result = try await SolidFillRedactionRenderer().render(document: document, sourceImage: source)
        XCTAssertEqual(result.bytes, Data([0, 0, 0, 255]) + source.bytes[4..<8] + Data([0, 0, 0, 255]))
    }

    func testDeterministicAcrossRepeatedRendersAndCandidateOrder() async throws {
        let dimensions = try PixelDimensions(width: 8, height: 6)
        let source = pixels(dimensions, colorSpace: .sRGB)
        let rects = [try ImageRect(x: 1, y: 1, width: 4, height: 3), try ImageRect(x: 3, y: 2, width: 4, height: 3)]
        let renderer = SolidFillRedactionRenderer()
        let document = try document(dimensions, manual: rects)
        let first = try await renderer.render(document: document, sourceImage: source)
        let second = try await renderer.render(document: document, sourceImage: source)
        let reversed = try await renderer.render(document: self.document(dimensions, manual: rects.reversed()), sourceImage: source)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first, reversed)
    }

    func testImportedFixtureHasNoSurvivingSourcePixelsInsideFills() async throws {
        let fixture = try FixtureLibrary.bundled().fixture(id: "env-file-light-2x")
        let imported = try await ImageIOImageImporter().importImage(from: fixture.imageURL)
        let rects = try fixture.groundTruth.spans.filter { $0.expectation == .sensitive }
            .flatMap(\.segments).map { try $0.rect.imageRect(in: imported.pixelDimensions) }
        XCTAssertFalse(rects.isEmpty)
        let document = try document(imported.pixelDimensions, manual: rects)
        let plan = try RedactionRenderPlan(document: document)
        let original = imported.pixels.bytes
        let result = try await SolidFillRedactionRenderer().render(document: document, sourceImage: imported.pixels)
        var incorrectPixels = 0
        var replacedPixels = 0
        result.bytes.withUnsafeBytes { (output: UnsafeRawBufferPointer) in
            original.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
                for y in 0..<imported.pixelDimensions.height {
                    for x in 0..<imported.pixelDimensions.width {
                        let i = (y * imported.pixelDimensions.width + x) * 4
                        if plan.covers(x: x, y: y) {
                            if output[i] != 0 || output[i + 1] != 0 || output[i + 2] != 0 || output[i + 3] != 255 {
                                incorrectPixels += 1
                            }
                            if (0..<4).contains(where: { output[i + $0] != input[i + $0] }) { replacedPixels += 1 }
                        } else if (0..<4).contains(where: { output[i + $0] != input[i + $0] }) {
                            incorrectPixels += 1
                        }
                    }
                }
            }
        }
        XCTAssertEqual(incorrectPixels, 0)
        XCTAssertGreaterThan(replacedPixels, 0)
        XCTAssertEqual(imported.pixels.bytes, original)
        XCTAssertEqual(result.layout, imported.pixels.layout)
    }

    func testRejectsMissingLayoutAndMismatchedDimensions() async throws {
        let dimensions = try PixelDimensions(width: 2, height: 2)
        let document = try document(dimensions)
        for (source, expected) in [
            (DecodedPixels(bytes: Data()), RedactionRenderingError.missingPixelLayout),
            (pixels(try PixelDimensions(width: 3, height: 2), colorSpace: .sRGB), .dimensionsMismatch),
        ] {
            do {
                _ = try await SolidFillRedactionRenderer().render(document: document, sourceImage: source)
                XCTFail("Expected invalid source to be rejected")
            } catch { XCTAssertEqual(error as? RedactionRenderingError, expected) }
        }
    }

    func testCancelledRenderReturnsNoOutput() async throws {
        let dimensions = try PixelDimensions(width: 2, height: 2)
        let source = pixels(dimensions, colorSpace: .sRGB)
        let document = try document(dimensions)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await SolidFillRedactionRenderer().render(document: document, sourceImage: source)
        }
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    private func pixels(_ dimensions: PixelDimensions, colorSpace: RenderingColorSpace) -> DecodedPixels {
        let layout = PixelBufferLayout(dimensions: dimensions, colorSpace: colorSpace)
        var bytes = Data()
        bytes.reserveCapacity(layout.byteCount)
        for index in 0..<(dimensions.width * dimensions.height) {
            bytes.append(UInt8(index % 61 + 1))
            bytes.append(UInt8(index % 47 + 1))
            bytes.append(UInt8(index % 31 + 1))
            bytes.append(128)
        }
        return DecodedPixels(bytes: bytes, layout: layout)
    }

    private func document(_ dimensions: PixelDimensions, manual: [ImageRect] = []) throws -> RedactionDocument {
        try RedactionDocument(sourceIdentity: SourceImageIdentity(), pixelDimensions: dimensions,
                              candidates: manual.map { .manual(region: RedactionRegion(rect: $0)) })
    }
}
