import Foundation
import RedScreenCore

// Helpers that score pipeline output against fixture ground truth.
//
// Reports identify fixtures, spans, segments, families, and IoU values only. They never include
// OCR text or labelled values, so they are safe to print in CI logs.

enum FixtureGeometry {
    static func area(_ rect: NormalizedRect) -> Double {
        rect.width * rect.height
    }

    static func intersectionArea(_ a: NormalizedRect, _ b: NormalizedRect) -> Double {
        let width = min(a.x + a.width, b.x + b.width) - max(a.x, b.x)
        let height = min(a.y + a.height, b.y + b.height) - max(a.y, b.y)
        return width > 0 && height > 0 ? width * height : 0
    }

    /// Intersection over union in `0...1`. Disjoint or edge-touching rectangles score 0.
    static func intersectionOverUnion(_ a: NormalizedRect, _ b: NormalizedRect) -> Double {
        let intersection = intersectionArea(a, b)
        guard intersection > 0 else { return 0 }
        return intersection / (area(a) + area(b) - intersection)
    }

    /// Fraction of `target` covered by the union of `covers`, computed exactly by coordinate
    /// compression so overlapping covers are not double counted.
    static func coverageFraction(of target: NormalizedRect, by covers: [NormalizedRect]) -> Double {
        let clipped: [(minX: Double, minY: Double, maxX: Double, maxY: Double)] = covers.compactMap {
            let minX = max($0.x, target.x)
            let minY = max($0.y, target.y)
            let maxX = min($0.x + $0.width, target.x + target.width)
            let maxY = min($0.y + $0.height, target.y + target.height)
            return minX < maxX && minY < maxY ? (minX, minY, maxX, maxY) : nil
        }
        guard !clipped.isEmpty else { return 0 }

        let xs = Array(Set(clipped.flatMap { [$0.minX, $0.maxX] })).sorted()
        let ys = Array(Set(clipped.flatMap { [$0.minY, $0.maxY] })).sorted()
        var covered = 0.0
        for (x0, x1) in zip(xs, xs.dropFirst()) {
            for (y0, y1) in zip(ys, ys.dropFirst()) where clipped.contains(where: {
                $0.minX <= x0 && $0.maxX >= x1 && $0.minY <= y0 && $0.maxY >= y1
            }) {
                covered += (x1 - x0) * (y1 - y0)
            }
        }
        return min(1, covered / area(target))
    }
}

/// One rectangle produced by a detector, composer, or renderer under test.
struct FixtureDetection: Equatable, Sendable {
    let rect: NormalizedRect
    let family: FixtureSecretFamily?

    init(rect: NormalizedRect, family: FixtureSecretFamily? = nil) {
        self.rect = rect
        self.family = family
    }

    init(
        imageRect: ImageRect,
        dimensions: PixelDimensions,
        family: FixtureSecretFamily? = nil
    ) throws {
        rect = try imageRect.normalized(in: dimensions, targetOrigin: .topLeft)
        self.family = family
    }
}

struct FixtureMatchTolerance: Equatable, Sendable {
    /// Minimum IoU for a detection to count as a correct localisation of a sensitive segment.
    let minimumIoU: Double

    init(minimumIoU: Double = 0.5) {
        precondition(minimumIoU > 0 && minimumIoU <= 1, "IoU tolerance must be in (0, 1]")
        self.minimumIoU = minimumIoU
    }
}

struct FixtureSegmentReference: Equatable, Hashable, Sendable, CustomStringConvertible {
    let spanID: String
    let segmentIndex: Int
    let family: FixtureSecretFamily
    let expectation: FixtureExpectation

    var description: String {
        "\(expectation.rawValue) span '\(spanID)' segment \(segmentIndex) [\(family.rawValue)]"
    }
}

struct FixtureMatch: Equatable, Sendable {
    let detectionIndex: Int
    let segment: FixtureSegmentReference
    let intersectionOverUnion: Double
    let detectedFamily: FixtureSecretFamily?
}

struct FixtureFalsePositive: Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        /// The detection overlaps no labelled span.
        case unexpectedRegion
        /// The detection overlaps a span that must stay visible.
        case benignOverlap(FixtureSegmentReference, intersectionOverUnion: Double)
        /// The detection only overlaps segments already claimed by better-matching detections.
        case duplicate(of: FixtureSegmentReference)
    }

    let detectionIndex: Int
    let reason: Reason
}

struct FixtureComparisonReport: Equatable, Sendable, CustomStringConvertible {
    let fixtureID: String
    let tolerance: FixtureMatchTolerance
    let truePositives: [FixtureMatch]
    let falsePositives: [FixtureFalsePositive]
    let falseNegatives: [FixtureSegmentReference]
    /// Detections that found a sensitive segment but localised it below the IoU tolerance.
    let geometryMismatches: [FixtureMatch]
    /// Detections on ambiguous spans. These are reported but never scored.
    let ambiguousMatches: [FixtureMatch]

    /// Correct localisations whose detector family differs from the ground-truth label.
    var familyMismatches: [FixtureMatch] {
        truePositives.filter { match in
            match.detectedFamily.map { $0 != match.segment.family } ?? false
        }
    }

    var isClean: Bool {
        falsePositives.isEmpty && falseNegatives.isEmpty && geometryMismatches.isEmpty
    }

    var description: String {
        func iou(_ value: Double) -> String { String(format: "%.3f", value) }
        var lines = [
            "Fixture \(fixtureID): TP=\(truePositives.count) FP=\(falsePositives.count) "
                + "FN=\(falseNegatives.count) geometry=\(geometryMismatches.count) "
                + "ambiguous=\(ambiguousMatches.count) (min IoU \(iou(tolerance.minimumIoU)))",
        ]
        for falsePositive in falsePositives {
            switch falsePositive.reason {
            case .unexpectedRegion:
                lines.append(
                    "  false positive: detection #\(falsePositive.detectionIndex) "
                        + "overlaps no labelled span"
                )
            case .benignOverlap(let segment, let value):
                lines.append(
                    "  false positive: detection #\(falsePositive.detectionIndex) "
                        + "overlaps \(segment) (IoU \(iou(value)))"
                )
            case .duplicate(let segment):
                lines.append(
                    "  false positive: detection #\(falsePositive.detectionIndex) "
                        + "duplicates another detection of \(segment)"
                )
            }
        }
        for segment in falseNegatives {
            lines.append("  false negative: \(segment) was not detected")
        }
        for match in geometryMismatches {
            lines.append(
                "  geometry mismatch: detection #\(match.detectionIndex) vs \(match.segment) "
                    + "IoU \(iou(match.intersectionOverUnion)) < \(iou(tolerance.minimumIoU))"
            )
        }
        for match in familyMismatches {
            lines.append(
                "  family mismatch: detection #\(match.detectionIndex) labelled "
                    + "\(match.detectedFamily?.rawValue ?? "none"), expected \(match.segment)"
            )
        }
        return lines.joined(separator: "\n")
    }
}

/// Matches detections to ground-truth span segments one-to-one.
///
/// Pairs are assigned greedily by descending IoU, breaking ties by detection index and then by
/// segment order, so results are deterministic. Each segment of a wrapped span is scored
/// separately, mirroring how a composer emits one rectangle per line.
struct FixtureGroundTruthComparator {
    let tolerance: FixtureMatchTolerance

    init(tolerance: FixtureMatchTolerance = FixtureMatchTolerance()) {
        self.tolerance = tolerance
    }

    func compare(
        _ detections: [FixtureDetection],
        against groundTruth: FixtureGroundTruth
    ) throws -> FixtureComparisonReport {
        var segments: [(reference: FixtureSegmentReference, rect: NormalizedRect)] = []
        for span in groundTruth.spans {
            for (index, segment) in span.segments.enumerated() {
                segments.append((
                    FixtureSegmentReference(
                        spanID: span.id,
                        segmentIndex: index,
                        family: span.family,
                        expectation: span.expectation
                    ),
                    try segment.rect.normalizedRect()
                ))
            }
        }

        var pairs: [(detection: Int, segment: Int, iou: Double)] = []
        for (detectionIndex, detection) in detections.enumerated() {
            for (segmentIndex, segment) in segments.enumerated() {
                let value = FixtureGeometry.intersectionOverUnion(detection.rect, segment.rect)
                if value > 0 { pairs.append((detectionIndex, segmentIndex, value)) }
            }
        }
        pairs.sort {
            if $0.iou != $1.iou { return $0.iou > $1.iou }
            if $0.detection != $1.detection { return $0.detection < $1.detection }
            return $0.segment < $1.segment
        }

        var assignedSegmentForDetection: [Int: (segment: Int, iou: Double)] = [:]
        var assignedSegments: Set<Int> = []
        for pair in pairs where assignedSegmentForDetection[pair.detection] == nil
            && !assignedSegments.contains(pair.segment) {
            assignedSegmentForDetection[pair.detection] = (pair.segment, pair.iou)
            assignedSegments.insert(pair.segment)
        }

        var truePositives: [FixtureMatch] = []
        var falsePositives: [FixtureFalsePositive] = []
        var geometryMismatches: [FixtureMatch] = []
        var ambiguousMatches: [FixtureMatch] = []

        for (detectionIndex, detection) in detections.enumerated() {
            guard let assignment = assignedSegmentForDetection[detectionIndex] else {
                let reason: FixtureFalsePositive.Reason =
                    if let best = pairs.first(where: { $0.detection == detectionIndex }) {
                        .duplicate(of: segments[best.segment].reference)
                    } else {
                        .unexpectedRegion
                    }
                falsePositives.append(
                    FixtureFalsePositive(detectionIndex: detectionIndex, reason: reason)
                )
                continue
            }
            let reference = segments[assignment.segment].reference
            let match = FixtureMatch(
                detectionIndex: detectionIndex,
                segment: reference,
                intersectionOverUnion: assignment.iou,
                detectedFamily: detection.family
            )
            switch reference.expectation {
            case .sensitive:
                if assignment.iou >= tolerance.minimumIoU {
                    truePositives.append(match)
                } else {
                    geometryMismatches.append(match)
                }
            case .ambiguous:
                ambiguousMatches.append(match)
            case .benign:
                falsePositives.append(FixtureFalsePositive(
                    detectionIndex: detectionIndex,
                    reason: .benignOverlap(reference, intersectionOverUnion: assignment.iou)
                ))
            }
        }

        let falseNegatives = segments.enumerated()
            .filter { index, segment in
                segment.reference.expectation == .sensitive && !assignedSegments.contains(index)
            }
            .map(\.element.reference)

        return FixtureComparisonReport(
            fixtureID: groundTruth.id,
            tolerance: tolerance,
            truePositives: truePositives,
            falsePositives: falsePositives,
            falseNegatives: falseNegatives,
            geometryMismatches: geometryMismatches,
            ambiguousMatches: ambiguousMatches
        )
    }
}
