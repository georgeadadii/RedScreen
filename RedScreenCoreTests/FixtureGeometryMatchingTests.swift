import Foundation
import XCTest

@testable import RedScreenCore

final class FixtureGeometryMatchingTests: XCTestCase {
    // MARK: - IoU and coverage

    func testIntersectionOverUnionForIdenticalDisjointAndPartialRectangles() throws {
        let a = try NormalizedRect(x: 0.1, y: 0.1, width: 0.4, height: 0.2)
        let b = try NormalizedRect(x: 0.3, y: 0.1, width: 0.4, height: 0.2)
        let disjoint = try NormalizedRect(x: 0.6, y: 0.5, width: 0.1, height: 0.1)
        let touching = try NormalizedRect(x: 0.5, y: 0.1, width: 0.1, height: 0.2)

        XCTAssertEqual(FixtureGeometry.intersectionOverUnion(a, a), 1, accuracy: 1e-12)
        XCTAssertEqual(FixtureGeometry.intersectionOverUnion(a, disjoint), 0)
        XCTAssertEqual(FixtureGeometry.intersectionOverUnion(a, touching), 0)
        // Overlap 0.2 x 0.2 = 0.04; union 0.08 + 0.08 - 0.04 = 0.12.
        XCTAssertEqual(FixtureGeometry.intersectionOverUnion(a, b), 1.0 / 3.0, accuracy: 1e-12)
        XCTAssertEqual(
            FixtureGeometry.intersectionOverUnion(a, b),
            FixtureGeometry.intersectionOverUnion(b, a)
        )
    }

    func testCoverageFractionDoesNotDoubleCountOverlappingCovers() throws {
        let target = try NormalizedRect(x: 0.2, y: 0.2, width: 0.4, height: 0.2)
        let left = try NormalizedRect(x: 0.1, y: 0.1, width: 0.3, height: 0.4)
        let overlapping = try NormalizedRect(x: 0.3, y: 0.2, width: 0.1, height: 0.2)
        let right = try NormalizedRect(x: 0.5, y: 0.25, width: 0.2, height: 0.1)

        XCTAssertEqual(FixtureGeometry.coverageFraction(of: target, by: []), 0)
        XCTAssertEqual(
            FixtureGeometry.coverageFraction(of: target, by: [left, overlapping]),
            0.5, accuracy: 1e-12
        )
        // Right cover adds 0.1 x 0.1 inside the target: (0.04 + 0.01) / 0.08.
        XCTAssertEqual(
            FixtureGeometry.coverageFraction(of: target, by: [left, overlapping, right]),
            0.625, accuracy: 1e-12
        )
        XCTAssertEqual(
            FixtureGeometry.coverageFraction(of: target, by: [target]), 1, accuracy: 1e-12
        )
    }

    // MARK: - Comparator against the real corpus

    func testExactGroundTruthDetectionsProduceACleanReport() throws {
        let truth = try fixture("env-diff-columns-light-2x")
        let report = try FixtureGroundTruthComparator()
            .compare(exactDetections(for: truth, expectations: [.sensitive, .ambiguous]), against: truth)

        XCTAssertTrue(report.isClean, report.description)
        XCTAssertEqual(report.truePositives.count, sensitiveSegmentCount(truth))
        XCTAssertEqual(report.ambiguousMatches.count, 1)
        XCTAssertTrue(report.familyMismatches.isEmpty)
        XCTAssertTrue(report.truePositives.allSatisfy { $0.intersectionOverUnion > 0.999 })
    }

    func testReportClassifiesMissesBenignHitsGeometryDuplicatesAndStrayRegions() throws {
        let truth = try fixture("terminal-wrapped-url-dark-1x")
        let password = try XCTUnwrap(truth.spans.first { $0.id == "wrapped-db-password" })
        let replica = try XCTUnwrap(truth.spans.first { $0.id == "wrapped-replica-url" })

        let firstSegment = try password.segments[0].rect.normalizedRect()
        let secondSegment = try password.segments[1].rect.normalizedRect()
        let shrunkSecond = try NormalizedRect(
            x: secondSegment.x,
            y: secondSegment.y,
            width: secondSegment.width * 0.3,
            height: secondSegment.height
        )
        let detections = [
            FixtureDetection(rect: firstSegment, family: .bearerToken),
            FixtureDetection(rect: firstSegment, family: .connectionString),
            FixtureDetection(rect: shrunkSecond, family: .connectionString),
            FixtureDetection(rect: try replica.segments[0].rect.normalizedRect()),
            FixtureDetection(rect: try NormalizedRect(x: 0.9, y: 0.9, width: 0.05, height: 0.05)),
        ]

        let report = try FixtureGroundTruthComparator(tolerance: FixtureMatchTolerance(minimumIoU: 0.5))
            .compare(detections, against: truth)

        XCTAssertEqual(report.truePositives.map(\.detectionIndex), [0])
        XCTAssertEqual(report.familyMismatches.map(\.detectionIndex), [0])
        XCTAssertEqual(report.geometryMismatches.map(\.detectionIndex), [2])
        XCTAssertEqual(report.geometryMismatches.first?.segment.segmentIndex, 1)
        XCTAssertTrue(report.falseNegatives.isEmpty, "Low-IoU hits are mismatches, not misses")
        XCTAssertEqual(report.falsePositives.count, 3)
        XCTAssertEqual(report.falsePositives[0].reason, .duplicate(of: report.truePositives[0].segment))
        if case .benignOverlap(let segment, _) = report.falsePositives[1].reason {
            XCTAssertEqual(segment.spanID, "wrapped-replica-url")
        } else {
            XCTFail("Expected a benign overlap")
        }
        XCTAssertEqual(report.falsePositives[2].reason, .unexpectedRegion)
        XCTAssertFalse(report.isClean)

        let description = report.description
        XCTAssertTrue(description.contains("FP=3"))
        XCTAssertTrue(description.contains("geometry mismatch: detection #2"))
        XCTAssertTrue(description.contains("family mismatch: detection #0"))
        XCTAssertTrue(description.contains("overlaps no labelled span"))
    }

    func testFamilyMismatchesMakeAReportUnclean() throws {
        // Regression: exact rectangles with the wrong family previously reported clean.
        let truth = try fixture("env-file-light-1x")
        let mislabelled = try exactDetections(for: truth, expectations: [.sensitive]).map {
            FixtureDetection(rect: $0.rect, family: .privateKeyHeader)
        }

        let report = try FixtureGroundTruthComparator().compare(mislabelled, against: truth)

        XCTAssertEqual(report.truePositives.count, 2)
        XCTAssertEqual(report.familyMismatches.count, 2)
        XCTAssertFalse(report.isClean, report.description)

        let unlabelled = mislabelled.map { FixtureDetection(rect: $0.rect) }
        XCTAssertTrue(
            try FixtureGroundTruthComparator().compare(unlabelled, against: truth).isClean
        )
    }

    func testMissingDetectionsAreReportedAsFalseNegatives() throws {
        let truth = try fixture("ci-log-dark-1x")
        let report = try FixtureGroundTruthComparator().compare([], against: truth)

        XCTAssertEqual(report.falseNegatives.count, sensitiveSegmentCount(truth))
        XCTAssertEqual(
            Set(report.falseNegatives.map(\.spanID)), ["ci-signing-secret", "ci-bearer"]
        )
        XCTAssertTrue(report.description.contains("false negative: sensitive span 'ci-bearer'"))
    }

    func testComparisonIsIndependentOfDetectionOrder() throws {
        let truth = try fixture("json-config-light-1x")
        let detections = try exactDetections(for: truth, expectations: [.sensitive, .benign])
        let forward = try FixtureGroundTruthComparator().compare(detections, against: truth)
        let reversed = try FixtureGroundTruthComparator()
            .compare(detections.reversed(), against: truth)

        XCTAssertEqual(forward.truePositives.count, reversed.truePositives.count)
        XCTAssertEqual(forward.falsePositives.count, reversed.falsePositives.count)
        XCTAssertEqual(
            Set(forward.truePositives.map(\.segment)), Set(reversed.truePositives.map(\.segment))
        )
    }

    func testDetectionsCanBeBuiltFromCanonicalImageRectangles() throws {
        let truth = try fixture("dashboard-cloud-light-2x")
        let dimensions = try truth.pixelDimensions()
        let secret = try XCTUnwrap(truth.spans.first { $0.expectation == .sensitive })
        let imageRect = try secret.segments[0].rect.imageRect(in: dimensions)

        let detection = try FixtureDetection(
            imageRect: imageRect, dimensions: dimensions, family: secret.family
        )
        let report = try FixtureGroundTruthComparator().compare([detection], against: truth)

        XCTAssertEqual(report.truePositives.count, 1)
        XCTAssertEqual(report.truePositives[0].intersectionOverUnion, 1, accuracy: 1e-6)
    }

    func testReportsNeverContainFixtureText() throws {
        for fixture in try FixtureLibrary.bundled().fixtures() {
            let truth = fixture.groundTruth
            let shifted = try exactDetections(
                for: truth, expectations: FixtureExpectation.allCases
            ).map { detection in
                FixtureDetection(
                    rect: try NormalizedRect(
                        x: detection.rect.x,
                        y: detection.rect.y,
                        width: detection.rect.width * 0.4,
                        height: detection.rect.height
                    ),
                    family: .highEntropyContextual
                )
            }
            let description = try FixtureGroundTruthComparator()
                .compare(shifted, against: truth).description

            for span in truth.spans {
                let value = try XCTUnwrap(truth.text(of: span))
                if value.count >= 4 {
                    XCTAssertFalse(description.contains(value), "\(truth.id) leaked \(span.id)")
                }
            }
            for box in truth.textBoxes where box.text.count >= 12 {
                XCTAssertFalse(description.contains(box.text), "\(truth.id) leaked \(box.id)")
            }
        }
    }

    // MARK: - Helpers

    private func fixture(_ id: String) throws -> FixtureGroundTruth {
        try FixtureLibrary.bundled().fixture(id: id).groundTruth
    }

    private func exactDetections(
        for truth: FixtureGroundTruth,
        expectations: [FixtureExpectation]
    ) throws -> [FixtureDetection] {
        try truth.spans.filter { expectations.contains($0.expectation) }.flatMap { span in
            try span.segments.map {
                FixtureDetection(rect: try $0.rect.normalizedRect(), family: span.family)
            }
        }
    }

    private func sensitiveSegmentCount(_ truth: FixtureGroundTruth) -> Int {
        truth.spans.filter { $0.expectation == .sensitive }.map(\.segments.count).reduce(0, +)
    }
}
