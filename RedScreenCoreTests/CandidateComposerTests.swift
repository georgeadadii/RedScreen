import Foundation
import XCTest

@testable import RedScreenCore

/// Geometry and provenance tests for `GeometricCandidateComposer` (issue #8).
final class CandidateComposerTests: XCTestCase {
    private let dimensions = try! PixelDimensions(width: 1_000, height: 500)
    private let composer = GeometricCandidateComposer()

    // MARK: - Exact and estimated spans

    func testWordAlignedSpanUsesTheWordBoxPlusPadding() throws {
        // "token RSFAKEvalue0001 here": words at x 100–150, 160–330, 340–380 (pixels).
        let observation = line("token RSFAKEvalue0001 here", x: 100, y: 100, width: 280, height: 20, words: [
            (0..<5, 100, 50), (6..<21, 160, 170), (22..<26, 340, 40),
        ])
        let candidate = try compose([detect(observation, 6..<21)], [observation]).first!

        XCTAssertEqual(candidate.geometry, .wordAligned)
        let rect = try XCTUnwrap(candidate.regions.first?.rect)
        let padding = 20 * 0.15
        XCTAssertEqual(rect.x, 160 - padding, accuracy: 1e-6)
        XCTAssertEqual(rect.maxX, 330 + padding, accuracy: 1e-6)
        XCTAssertEqual(rect.y, 100 - padding, accuracy: 1e-6)
        XCTAssertEqual(rect.maxY, 120 + padding, accuracy: 1e-6)
    }

    func testValueInsideAWordIsEstimatedFromCharacterPositions() throws {
        // Monospace 10 px per character; the value starts after "API_KEY=" (8 characters).
        let text = "API_KEY=RSFAKE-key-6b2d91"
        let observation = line(text, x: 100, y: 50, width: 250, height: 20, words: [(0..<25, 100, 250)])
        let candidate = try compose([detect(observation, 8..<25)], [observation]).first!

        XCTAssertEqual(candidate.geometry, .estimated)
        XCTAssertTrue(candidate.needsGeometryReview)
        let rect = try XCTUnwrap(candidate.regions.first?.rect)
        // Margin: 0.6 characters plus 0.1 per character of distance from the nearest edge (8),
        // with the growth capped at 1.2 characters.
        let margin = 10 * (0.6 + 0.8)
        XCTAssertEqual(rect.x, 180 - margin - 3, accuracy: 1e-6, "Label stays visible")
        XCTAssertEqual(rect.maxX, 350 + 3, accuracy: 1e-6, "Clipped to the word, then padded")
    }

    func testWithoutWordBoxesTheLineIsUsedIgnoringIndentation() throws {
        // Leading spaces are not inside the OCR box, which hugs visible text.
        let text = "    password: RSFAKE-pw"
        let observation = line(text, x: 200, y: 10, width: 190, height: 20, words: [])
        let candidate = try compose([detect(observation, 14..<23)], [observation]).first!

        XCTAssertEqual(candidate.geometry, .estimated)
        let rect = try XCTUnwrap(candidate.regions.first?.rect)
        // 19 visible characters over 190 px: the value starts at character 10, 9 from the end.
        XCTAssertEqual(rect.x, 200 + 100 - 10 * (0.6 + 0.9) - 3, accuracy: 1e-6)
        XCTAssertEqual(rect.maxX, 390 + 3, accuracy: 1e-6)
    }

    func testUnusableGeometryFallsBackToTheWholeLineAndIsFlagged() throws {
        let observation = line("   ", x: 10, y: 10, width: 100, height: 20, words: [])
        let candidate = try compose([detect(observation, 0..<3)], [observation]).first!

        XCTAssertEqual(candidate.geometry, .lineFallback)
        XCTAssertTrue(candidate.needsGeometryReview)
        XCTAssertEqual(candidate.regions.first?.rect.width ?? 0, 100 + 6, accuracy: 1e-6)
    }

    // MARK: - Grouping and provenance

    func testWrappedValueBecomesOneCandidateWithARectanglePerLine() throws {
        let first = line("DATABASE_URL=postgres://app_user:RSFAKE-", x: 50, y: 100, width: 400, height: 20, words: [])
        let second = line("Pg-9f8e7d@db.internal.test:5432/orders", x: 50, y: 130, width: 380, height: 20, words: [])
        let detection = try SecretDetection(
            evidence: evidence([first.id, second.id], rule: "connection-string.password.wrapped"),
            family: .connectionString,
            severity: .high,
            assessment: .likely,
            spans: [
                DetectedTextSpan(observationID: first.id, utf16Range: 33..<40),
                DetectedTextSpan(observationID: second.id, utf16Range: 0..<9),
            ]
        )

        let candidates = try compose([detection], [first, second])

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].regions.count, 2)
        XCTAssertLessThan(candidates[0].regions[0].rect.y, candidates[0].regions[1].rect.y)
        XCTAssertEqual(candidates[0].detectionIDs, [detection.id])
    }

    func testPrivateKeyBlockIsCoveredAsOneRectangleIncludingGaps() throws {
        let lines = [
            line("-----BEGIN RSA PRIVATE KEY-----", x: 50, y: 100, width: 300, height: 20, words: []),
            line("RSFAKEkeyBodyLine0001", x: 50, y: 130, width: 420, height: 20, words: []),
            // A body line OCR missed would sit at y 160; the block still covers it.
            line("-----END RSA PRIVATE KEY-----", x: 50, y: 190, width: 280, height: 20, words: []),
        ]
        let detection = try SecretDetection(
            evidence: evidence(lines.map(\.id), rule: "private-key.block"),
            family: .privateKey, severity: .critical, assessment: .likely,
            spans: lines.map { DetectedTextSpan(observationID: $0.id, utf16Range: 0..<$0.text.utf16.count) }
        )

        let candidate = try XCTUnwrap(try compose([detection], lines).first)

        XCTAssertEqual(candidate.regions.count, 1)
        let rect = candidate.regions[0].rect
        XCTAssertLessThanOrEqual(rect.y, 100)
        XCTAssertGreaterThanOrEqual(rect.maxY, 210)
        XCTAssertGreaterThanOrEqual(rect.maxX, 470, "Widest line sets the block width")
        XCTAssertEqual(candidate.severity, .critical)
    }

    func testOverlappingFindingsMergeIntoOneCandidateWithCombinedEvidence() throws {
        let observation = line("token RSFAKEvalue0001 here", x: 100, y: 100, width: 280, height: 20, words: [
            (0..<5, 100, 50), (6..<21, 160, 170), (22..<26, 340, 40),
        ])
        let a = try detect(observation, 6..<21, rule: "provider.example", assessment: .needsReview)
        let b = try detect(observation, 6..<18, rule: "high-entropy.contextual", assessment: .likely)

        let candidates = try compose([a, b], [observation])

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(Set(candidates[0].evidence.map(\.ruleID.rawValue)),
                       ["provider.example", "high-entropy.contextual"])
        XCTAssertEqual(Set(candidates[0].detectionIDs), [a.id, b.id])
        XCTAssertEqual(candidates[0].regions.count, 1, "Overlapping rectangles are merged")
        XCTAssertEqual(candidates[0].assessment, .likely)
        XCTAssertEqual(candidates[0].disposition, .included)
        XCTAssertEqual(candidates[0].geometry, .estimated, "Worst geometry wins")
    }

    func testSeparateFindingsStaySeparateAndAreSortedInReadingOrder() throws {
        let lower = line("password=RSFAKE-two", x: 50, y: 300, width: 190, height: 20, words: [])
        let upper = line("password=RSFAKE-one", x: 50, y: 100, width: 190, height: 20, words: [])
        let right = line("token=RSFAKE-three", x: 600, y: 100, width: 180, height: 20, words: [])

        let candidates = try compose(
            [detect(lower, 9..<19), detect(right, 6..<18), detect(upper, 9..<19, assessment: .needsReview)],
            [lower, upper, right]
        )

        XCTAssertEqual(candidates.count, 3)
        let firstXs = candidates.map { $0.regions[0].rect.x }
        let firstYs = candidates.map { $0.regions[0].rect.y }
        XCTAssertLessThan(firstYs[0], firstYs[2])
        XCTAssertLessThan(firstXs[0], firstXs[1])
        XCTAssertEqual(candidates[0].disposition, .pending, "Findings to review start pending")
        XCTAssertEqual(candidates[1].disposition, .included)
    }

    // MARK: - Padding and bounds

    func testPaddingScalesWithLineHeightAndIsClampedToTheImage() throws {
        let tall = line("secret=RSFAKEtallvalue", x: 0, y: 0, width: 220, height: 100, words: [])
        let atEdge = line("secret=RSFAKEedgevalue", x: 780, y: 480, width: 220, height: 20, words: [])

        let candidates = try compose([detect(tall, 7..<22), detect(atEdge, 7..<22)], [tall, atEdge])

        let tallRect = try XCTUnwrap(candidates.first { $0.regions[0].rect.y == 0 }?.regions[0].rect)
        XCTAssertEqual(tallRect.height, 100 + 15, accuracy: 1e-6, "15% padding, clamped at the top")
        for candidate in candidates {
            for region in candidate.regions {
                XCTAssertTrue(region.rect.isContained(in: dimensions))
                XCTAssertGreaterThanOrEqual(region.rect.x, 0)
                XCTAssertGreaterThanOrEqual(region.rect.y, 0)
            }
        }
        let edgeRect = try XCTUnwrap(candidates.first { $0.regions[0].rect.y > 400 }?.regions[0].rect)
        XCTAssertEqual(edgeRect.maxX, 1_000, accuracy: 1e-9)
        XCTAssertEqual(edgeRect.maxY, 500, accuracy: 1e-9)
    }

    func testUnknownObservationIsRejected() throws {
        let observation = line("password=RSFAKE-pw", x: 10, y: 10, width: 180, height: 20, words: [])
        XCTAssertThrowsError(try composer.composeCandidates(
            from: [detect(observation, 9..<18)], observations: [], dimensions: dimensions
        ))
    }

    func testDocumentAcceptsComposedCandidatesAndRejectsUnknownDetections() throws {
        let observation = line("password=RSFAKE-pw-doc", x: 10, y: 10, width: 220, height: 20, words: [])
        let detection = try detect(observation, 9..<22)
        let document = try RedactionDocument(
            sourceIdentity: SourceImageIdentity(),
            pixelDimensions: dimensions,
            observations: [observation]
        ).replacingDetections([detection])
        let candidates = try compose([detection], [observation])

        let composed = try document.replacingCandidates(candidates)
        XCTAssertEqual(composed.processingState, .readyForReview)
        XCTAssertEqual(composed.candidates.first?.detectionIDs, [detection.id])

        let withoutDetections = try document.replacingDetections([])
        XCTAssertThrowsError(try withoutDetections.replacingCandidates(candidates)) {
            XCTAssertEqual($0 as? DomainModelError, .unknownDetection)
        }
    }

    // MARK: - Property test

    func testRandomInputsAlwaysYieldFiniteInBoundsDeterministicCandidates() throws {
        var generator = SeededGenerator(seed: 0xC0FFEE)
        for _ in 0..<300 {
            var observations: [OCRObservation] = []
            var detections: [SecretDetection] = []
            for _ in 0..<Int.random(in: 1...8, using: &generator) {
                let length = Int.random(in: 1...60, using: &generator)
                let text = String((0..<length).map { _ in "aZ9 =:-é😀".randomElement(using: &generator)! })
                let utf16 = text.utf16.count
                let x = Double.random(in: 0...0.95, using: &generator)
                let y = Double.random(in: 0...0.95, using: &generator)
                let box = try NormalizedRect(
                    x: x, y: y,
                    width: Double.random(in: 0.001...(1 - x), using: &generator),
                    height: Double.random(in: 0.001...(1 - y), using: &generator)
                )
                var segments: [OCRTextSegment] = []
                if Bool.random(using: &generator), utf16 > 1 {
                    let cut = Int.random(in: 1..<utf16, using: &generator)
                    segments = [
                        OCRTextSegment(utf16Range: 0..<cut, boundingBox: box),
                        OCRTextSegment(utf16Range: cut..<utf16, boundingBox: box),
                    ]
                }
                let observation = OCRObservation(
                    text: text, boundingBox: box,
                    boundingBoxOrigin: Bool.random(using: &generator) ? .topLeft : .bottomLeft,
                    confidence: try Confidence(0.5), segments: segments
                )
                observations.append(observation)
                let start = Int.random(in: 0..<utf16, using: &generator)
                let end = Int.random(in: (start + 1)...utf16, using: &generator)
                detections.append(try detect(observation, start..<end,
                    assessment: Bool.random(using: &generator) ? .likely : .needsReview))
            }

            let first = try composer.composeCandidates(from: detections, observations: observations, dimensions: dimensions)
            let second = try composer.composeCandidates(from: detections, observations: observations, dimensions: dimensions)
            XCTAssertEqual(first.map(\.regions.count), second.map(\.regions.count))
            XCTAssertEqual(first.flatMap { $0.regions.map(\.rect) }, second.flatMap { $0.regions.map(\.rect) })
            XCTAssertEqual(Set(first.flatMap(\.detectionIDs)), Set(detections.map(\.id)), "Nothing is lost")
            for candidate in first {
                for region in candidate.regions {
                    let rect = region.rect
                    XCTAssertTrue([rect.x, rect.y, rect.width, rect.height].allSatisfy(\.isFinite))
                    XCTAssertGreaterThan(rect.width, 0)
                    XCTAssertGreaterThan(rect.height, 0)
                    XCTAssertTrue(rect.isContained(in: dimensions))
                }
            }
        }
    }

    // MARK: - Helpers

    private func compose(_ detections: [SecretDetection], _ observations: [OCRObservation]) throws
        -> [RedactionCandidate] {
        try composer.composeCandidates(from: detections, observations: observations, dimensions: dimensions)
    }

    /// An observation in top-left pixel units, with optional word boxes `(range, x, width)`.
    private func line(
        _ text: String, x: Double, y: Double, width: Double, height: Double,
        words: [(Range<Int>, Double, Double)]
    ) -> OCRObservation {
        let w = Double(dimensions.width)
        let h = Double(dimensions.height)
        let segments = words.map { range, wordX, wordWidth in
            OCRTextSegment(
                utf16Range: range,
                boundingBox: try! NormalizedRect(x: wordX / w, y: y / h, width: wordWidth / w, height: height / h)
            )
        }
        return OCRObservation(
            text: text,
            boundingBox: try! NormalizedRect(x: x / w, y: y / h, width: width / w, height: height / h),
            boundingBoxOrigin: .topLeft,
            confidence: try! Confidence(0.9),
            segments: segments
        )
    }

    private func evidence(_ ids: [UUID], rule: String) throws -> DetectionEvidence {
        try DetectionEvidence(ruleID: DetectorRuleID(rule), observationIDs: ids, confidence: Confidence(0.9))
    }

    private func detect(
        _ observation: OCRObservation,
        _ range: Range<Int>,
        rule: String = "test.rule",
        assessment: DetectionAssessment = .likely
    ) throws -> SecretDetection {
        try SecretDetection(
            evidence: evidence([observation.id], rule: rule),
            family: .credentialKeyword,
            severity: .high,
            assessment: assessment,
            spans: [DetectedTextSpan(observationID: observation.id, utf16Range: range)]
        )
    }
}
