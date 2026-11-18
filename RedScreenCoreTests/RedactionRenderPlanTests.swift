import Foundation
import XCTest

@testable import RedScreenCore

/// Tests for the render plan, the first slice of the redaction renderer (issue #9, RED-5).
final class RedactionRenderPlanTests: XCTestCase {
    private let dimensions = try! PixelDimensions(width: 100, height: 50)

    func testFractionalRectanglesRoundOutwardSoNoSourcePixelIsHalfCovered() throws {
        let plan = try RedactionRenderPlan(document: document([
            candidate(try ImageRect(x: 10.4, y: 5.6, width: 20.2, height: 3.1), .included),
        ]))

        XCTAssertEqual(plan.fills, [try PixelRect(x: 10, y: 5, width: 21, height: 4, dimensions: dimensions)])
        // Edge pixels touched by a fraction of the rectangle are fully covered.
        XCTAssertTrue(plan.covers(x: 10, y: 5))
        XCTAssertTrue(plan.covers(x: 30, y: 8))
        XCTAssertFalse(plan.covers(x: 31, y: 8))
        XCTAssertFalse(plan.covers(x: 9, y: 5))
    }

    func testEdgeTouchingRectanglesAreClampedToTheImage() throws {
        let plan = try RedactionRenderPlan(document: document([
            candidate(try ImageRect(x: 90.5, y: 45.5, width: 9.5, height: 4.5), .included),
            candidate(try ImageRect(x: 0, y: 0, width: 0.25, height: 0.25), .included),
        ]))

        XCTAssertEqual(plan.fills, [
            try PixelRect(x: 0, y: 0, width: 1, height: 1, dimensions: dimensions),
            try PixelRect(x: 90, y: 45, width: 10, height: 5, dimensions: dimensions),
        ])
        XCTAssertTrue(plan.covers(x: 99, y: 49), "Bottom-right image pixel")
    }

    func testOnlyIncludedAndManualCandidatesArePainted() throws {
        let rect = try ImageRect(x: 1, y: 1, width: 4, height: 4)
        let plan = try RedactionRenderPlan(document: document([
            candidate(try ImageRect(x: 10, y: 1, width: 4, height: 4), .pending),
            candidate(try ImageRect(x: 20, y: 1, width: 4, height: 4), .excluded),
            candidate(rect, .included),
        ], manual: [try ImageRect(x: 40, y: 1, width: 4, height: 4)]))

        XCTAssertEqual(plan.fills.map(\.x), [1, 40])
        XCTAssertFalse(plan.covers(x: 11, y: 2), "Pending stays visible until the user decides")
        XCTAssertFalse(plan.covers(x: 21, y: 2), "Excluded leaves source pixels unchanged")
    }

    func testManualAndDetectedRectanglesPaintIdentically() throws {
        let rect = try ImageRect(x: 12.5, y: 7.25, width: 30, height: 9.5)
        let detected = try RedactionRenderPlan(document: document([candidate(rect, .included)]))
        let manual = try RedactionRenderPlan(document: document([], manual: [rect]))

        XCTAssertEqual(detected.fills, manual.fills)
    }

    func testEveryRegionOfAMultiRegionCandidateIsPaintedAndDuplicatesCollapse() throws {
        let top = try ImageRect(x: 5, y: 5, width: 40, height: 8)
        let bottom = try ImageRect(x: 5, y: 20, width: 25, height: 8)
        let plan = try RedactionRenderPlan(document: document([
            candidate([top, bottom], .included),
            candidate(top, .included),
        ]))

        XCTAssertEqual(plan.fills.count, 2)
        XCTAssertTrue(plan.covers(x: 6, y: 6))
        XCTAssertTrue(plan.covers(x: 6, y: 21))
    }

    func testFillOrderIsDeterministicRegardlessOfCandidateOrder() throws {
        let rects = [
            try ImageRect(x: 50, y: 30, width: 5, height: 5),
            try ImageRect(x: 2, y: 30, width: 5, height: 5),
            try ImageRect(x: 70, y: 2, width: 5, height: 5),
        ]
        let forward = try RedactionRenderPlan(document: document(rects.map { candidate($0, .included) }))
        let reversed = try RedactionRenderPlan(document: document(rects.reversed().map { candidate($0, .included) }))

        XCTAssertEqual(forward, reversed)
        XCTAssertEqual(forward.fills.map { [$0.y, $0.x] }, [[2, 70], [30, 2], [30, 50]])
    }

    // MARK: - Helpers

    private let observation = OCRObservation(
        text: "synthetic",
        boundingBox: try! NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1),
        boundingBoxOrigin: .topLeft,
        confidence: try! Confidence(0.9)
    )

    private func candidate(_ rect: ImageRect, _ disposition: RedactionDisposition) -> RedactionCandidate {
        candidate([rect], disposition)
    }

    private func candidate(_ rects: [ImageRect], _ disposition: RedactionDisposition) -> RedactionCandidate {
        try! RedactionCandidate(
            regions: rects.map { RedactionRegion(rect: $0) },
            evidence: [DetectionEvidence(
                ruleID: DetectorRuleID("test.rule"),
                observationIDs: [observation.id],
                confidence: Confidence(0.9)
            )],
            disposition: disposition
        )
    }

    private func document(
        _ candidates: [RedactionCandidate],
        manual: [ImageRect] = []
    ) throws -> RedactionDocument {
        var document = try RedactionDocument(
            sourceIdentity: SourceImageIdentity(),
            pixelDimensions: dimensions,
            observations: [observation]
        ).replacingCandidates(candidates)
        for rect in manual {
            document = try document.addingManualRegion(RedactionRegion(rect: rect))
        }
        return document
    }
}
