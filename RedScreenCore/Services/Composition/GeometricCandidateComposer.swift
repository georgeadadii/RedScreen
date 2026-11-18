import Foundation

/// Tunable geometry for candidate composition.
public struct CandidateCompositionPolicy: Equatable, Sendable {
    /// Minimum padding added around every rectangle, in image pixels.
    public var minimumPaddingPixels: Double
    /// Padding as a fraction of the line height; the larger of the two applies, so padding
    /// scales with 1x and 2x screenshots.
    public var paddingFractionOfLineHeight: Double
    /// Extra width, in estimated character widths, added to each side of an estimated extent.
    public var estimatedMarginCharacters: Double
    /// Additional margin per character of distance from the nearest known edge of the word or
    /// line, covering width drift in proportional fonts.
    public var estimatedMarginGrowthPerCharacter: Double
    /// Upper bound on that growth, in characters, so long monospace lines don't hide labels.
    public var maximumMarginGrowthCharacters: Double

    public static let standard = CandidateCompositionPolicy(
        minimumPaddingPixels: 2,
        paddingFractionOfLineHeight: 0.15,
        estimatedMarginCharacters: 0.6,
        estimatedMarginGrowthPerCharacter: 0.1,
        maximumMarginGrowthCharacters: 1.2
    )

    public init(
        minimumPaddingPixels: Double,
        paddingFractionOfLineHeight: Double,
        estimatedMarginCharacters: Double,
        estimatedMarginGrowthPerCharacter: Double,
        maximumMarginGrowthCharacters: Double
    ) {
        self.minimumPaddingPixels = minimumPaddingPixels
        self.paddingFractionOfLineHeight = paddingFractionOfLineHeight
        self.estimatedMarginCharacters = estimatedMarginCharacters
        self.estimatedMarginGrowthPerCharacter = estimatedMarginGrowthPerCharacter
        self.maximumMarginGrowthCharacters = maximumMarginGrowthCharacters
    }
}

/// Turns detector spans into minimal, padded, in-bounds image rectangles (issue #8).
///
/// Geometry, from best to most conservative:
/// 1. **Word-aligned:** the value starts and ends on OCR word boundaries; the word boxes are used.
/// 2. **Estimated:** the value is part of a word or line (for example `KEY=value` with no
///    spaces). Its extent is interpolated from character positions inside the word or line box
///    and widened by `estimatedMarginCharacters` on each side, favouring over-coverage.
/// 3. **Line fallback:** without usable geometry the whole OCR line is covered and the candidate
///    is flagged for review.
///
/// Private key blocks are covered as one rectangle spanning the whole block.
/// Every rectangle is padded, clamped to the image, and checked for finiteness and positive size.
/// Findings whose rectangles overlap become one candidate with combined evidence, and rectangles
/// that overlap within a candidate are merged. Output is sorted in reading order. Likely findings
/// start `included` (over-coverage is the safe default); findings needing review start `pending`.
/// No matched text is copied into candidates.
public struct GeometricCandidateComposer: CandidateComposer {
    public let policy: CandidateCompositionPolicy

    public init(policy: CandidateCompositionPolicy = .standard) {
        self.policy = policy
    }

    public func composeCandidates(
        from detections: [SecretDetection],
        observations: [OCRObservation],
        dimensions: PixelDimensions
    ) throws -> [RedactionCandidate] {
        let byID = Dictionary(uniqueKeysWithValues: observations.map { ($0.id, $0) })
        var drafts: [Draft] = []
        for detection in detections {
            var rects: [ImageRect] = []
            var geometry = CandidateGeometry.wordAligned
            for span in detection.spans {
                guard let observation = byID[span.observationID] else {
                    throw DomainModelError.unknownObservation
                }
                let placed = try place(span, in: observation, dimensions: dimensions)
                rects.append(placed.rect)
                geometry = max(geometry, placed.geometry)
            }
            guard !rects.isEmpty else { continue }
            // A private key block is covered as one rectangle from BEGIN to END, so lines that
            // OCR missed or boxed narrowly inside the block are covered too.
            if detection.family == .privateKey, let first = rects.first {
                let block = rects.dropFirst().reduce(Extent(first)) { $0.union(Extent($1)) }
                rects = [try ImageRect(x: block.minX, y: block.minY, width: block.width, height: block.height)]
            }
            drafts.append(Draft(
                rects: rects,
                evidence: [detection.evidence],
                detectionIDs: [detection.id],
                geometry: geometry,
                assessment: detection.assessment,
                severity: detection.severity
            ))
        }

        return try merge(drafts).sorted(by: Draft.readingOrder).map { draft in
            let regions = draft.rects.sorted(by: Self.readingOrder).map { RedactionRegion(rect: $0) }
            return try RedactionCandidate(
                regions: regions,
                evidence: draft.evidence,
                detectionIDs: draft.detectionIDs,
                geometry: draft.geometry,
                assessment: draft.assessment,
                severity: draft.severity,
                disposition: draft.assessment == .likely ? .included : .pending
            )
        }
    }

    // MARK: - Placing one span

    struct Placement {
        let rect: ImageRect
        let geometry: CandidateGeometry
    }

    func place(
        _ span: DetectedTextSpan,
        in observation: OCRObservation,
        dimensions: PixelDimensions
    ) throws -> Placement {
        let line = try observation.imageRect(in: dimensions)
        let text = observation.text
        let utf16Count = text.utf16.count
        let range = max(0, span.utf16Range.lowerBound)..<min(utf16Count, span.utf16Range.upperBound)

        let raw: (rect: Extent, geometry: CandidateGeometry)
        if range.isEmpty {
            raw = (Extent(line), .lineFallback)
        } else if let wordPlacement = try placeUsingSegments(range, in: observation, dimensions: dimensions) {
            raw = wordPlacement
        } else if let estimate = estimate(range, within: Extent(line), covering: inkRange(of: text), in: text) {
            raw = (estimate, .estimated)
        } else {
            raw = (Extent(line), .lineFallback)
        }
        return Placement(rect: try padded(raw.rect, lineHeight: line.height, dimensions: dimensions),
                         geometry: raw.geometry)
    }

    /// Uses OCR word boxes: exact when the span is word-aligned, estimated inside the boundary
    /// words otherwise.
    private func placeUsingSegments(
        _ range: Range<Int>,
        in observation: OCRObservation,
        dimensions: PixelDimensions
    ) throws -> (Extent, CandidateGeometry)? {
        let segments = observation.segments
            .filter { $0.utf16Range.overlaps(range) }
            .sorted { $0.utf16Range.lowerBound < $1.utf16Range.lowerBound }
        guard let first = segments.first, let last = segments.last else { return nil }
        let firstRect = Extent(try observation.imageRect(for: first, in: dimensions))
        let lastRect = Extent(try observation.imageRect(for: last, in: dimensions))
        let union = try segments.map { Extent(try observation.imageRect(for: $0, in: dimensions)) }
            .reduce(firstRect) { $0.union($1) }

        let alignedStart = range.lowerBound <= first.utf16Range.lowerBound
        let alignedEnd = range.upperBound >= last.utf16Range.upperBound
        if alignedStart && alignedEnd { return (union, .wordAligned) }

        let text = observation.text
        var minX = union.minX
        var maxX = union.maxX
        if !alignedStart,
           let start = estimate(range, within: firstRect, covering: first.utf16Range, in: text) {
            minX = start.minX
        }
        if !alignedEnd,
           let end = estimate(range, within: lastRect, covering: last.utf16Range, in: text) {
            maxX = end.maxX
        }
        guard maxX > minX else { return nil }
        return (Extent(minX: minX, minY: union.minY, maxX: maxX, maxY: union.maxY), .estimated)
    }

    /// Interpolates the horizontal extent of `range` inside `box`, which is known to contain the
    /// characters of `boxRange`, then widens it by the safety margin and clips it to `box`.
    private func estimate(
        _ range: Range<Int>,
        within box: Extent,
        covering boxRange: Range<Int>?,
        in text: String
    ) -> Extent? {
        guard let boxRange, !boxRange.isEmpty else { return nil }
        let clipped = range.clamped(to: boxRange)
        guard !clipped.isEmpty else { return nil }
        let characters = characterOffsets(in: text)
        func index(_ utf16Offset: Int) -> Int {
            characters.firstIndex { $0 >= utf16Offset } ?? characters.count - 1
        }
        let boxStart = index(boxRange.lowerBound)
        let boxEnd = index(boxRange.upperBound)
        let count = boxEnd - boxStart
        guard count > 0, box.width > 0 else { return nil }
        let characterWidth = box.width / Double(count)
        // Uniform character widths are exact for monospace text but drift in proportional text
        // the further a position is from a known edge, so the margin grows with that distance.
        func margin(at position: Int) -> Double {
            let distance = Double(min(position - boxStart, boxEnd - position))
            let growth = min(
                policy.estimatedMarginGrowthPerCharacter * distance,
                policy.maximumMarginGrowthCharacters
            )
            return characterWidth * (policy.estimatedMarginCharacters + growth)
        }
        let startIndex = index(clipped.lowerBound)
        let endIndex = index(clipped.upperBound)
        let minX = box.minX + Double(startIndex - boxStart) * characterWidth - margin(at: startIndex)
        let maxX = box.minX + Double(endIndex - boxStart) * characterWidth + margin(at: endIndex)
        let result = Extent(
            minX: max(box.minX, minX), minY: box.minY, maxX: min(box.maxX, maxX), maxY: box.maxY
        )
        guard result.maxX > result.minX, result.isFinite else { return nil }
        return result
    }

    /// UTF-16 offset of every character boundary, including the end of the text.
    private func characterOffsets(in text: String) -> [Int] {
        var offsets: [Int] = []
        var offset = 0
        for character in text {
            offsets.append(offset)
            offset += character.utf16.count
        }
        offsets.append(offset)
        return offsets
    }

    /// The text range a line box covers: OCR boxes hug ink, so surrounding whitespace is outside.
    private func inkRange(of text: String) -> Range<Int>? {
        let utf16 = Array(text.utf16)
        guard let first = utf16.firstIndex(where: { $0 != 0x20 && $0 != 0x09 }),
              let last = utf16.lastIndex(where: { $0 != 0x20 && $0 != 0x09 }) else {
            return nil
        }
        return first..<(last + 1)
    }

    private func padded(
        _ extent: Extent,
        lineHeight: Double,
        dimensions: PixelDimensions
    ) throws -> ImageRect {
        let padding = max(policy.minimumPaddingPixels, lineHeight * policy.paddingFractionOfLineHeight)
        let minX = max(0, extent.minX - padding)
        let minY = max(0, extent.minY - padding)
        let maxX = min(Double(dimensions.width), extent.maxX + padding)
        let maxY = min(Double(dimensions.height), extent.maxY + padding)
        guard [minX, minY, maxX, maxY].allSatisfy(\.isFinite), maxX > minX, maxY > minY else {
            throw GeometryError.nonPositiveSize
        }
        return try ImageRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: - Merging

    struct Draft {
        var rects: [ImageRect]
        var evidence: [DetectionEvidence]
        var detectionIDs: [UUID]
        var geometry: CandidateGeometry
        var assessment: DetectionAssessment
        var severity: SecretSeverity

        func overlaps(_ other: Draft) -> Bool {
            rects.contains { left in other.rects.contains { Extent(left).intersects(Extent($0)) } }
        }

        mutating func absorb(_ other: Draft) {
            rects += other.rects
            for item in other.evidence where !evidence.contains(item) { evidence.append(item) }
            detectionIDs += other.detectionIDs.filter { !detectionIDs.contains($0) }
            geometry = max(geometry, other.geometry)
            if other.assessment == .likely { assessment = .likely }
            severity = max(severity, other.severity)
        }

        static func readingOrder(_ a: Draft, _ b: Draft) -> Bool {
            GeometricCandidateComposer.readingOrder(
                a.rects.min(by: GeometricCandidateComposer.readingOrder)!,
                b.rects.min(by: GeometricCandidateComposer.readingOrder)!
            )
        }
    }

    /// Joins drafts whose rectangles overlap, then merges overlapping rectangles inside each.
    private func merge(_ drafts: [Draft]) -> [Draft] {
        var groups: [Draft] = []
        for draft in drafts {
            var combined = draft
            var remaining: [Draft] = []
            for group in groups {
                if group.overlaps(combined) {
                    combined.absorb(group)
                } else {
                    remaining.append(group)
                }
            }
            groups = remaining + [combined]
        }
        return groups.map { group in
            var merged = group
            merged.rects = mergeOverlapping(group.rects)
            return merged
        }
    }

    private func mergeOverlapping(_ rects: [ImageRect]) -> [ImageRect] {
        var extents = rects.map(Extent.init)
        var changed = true
        while changed {
            changed = false
            outer: for i in extents.indices {
                for j in extents.indices where j > i && extents[i].intersects(extents[j]) {
                    extents[i] = extents[i].union(extents[j])
                    extents.remove(at: j)
                    changed = true
                    break outer
                }
            }
        }
        return extents.compactMap {
            try? ImageRect(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height)
        }
    }

    static func readingOrder(_ a: ImageRect, _ b: ImageRect) -> Bool {
        (a.y, a.x, a.maxY, a.maxX) < (b.y, b.x, b.maxY, b.maxX)
    }
}

/// Plain edge representation used while composing.
struct Extent: Equatable {
    var minX: Double
    var minY: Double
    var maxX: Double
    var maxY: Double

    init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    init(_ rect: ImageRect) {
        self.init(minX: rect.x, minY: rect.y, maxX: rect.maxX, maxY: rect.maxY)
    }

    var width: Double { maxX - minX }
    var height: Double { maxY - minY }
    var isFinite: Bool { [minX, minY, maxX, maxY].allSatisfy(\.isFinite) }

    func union(_ other: Extent) -> Extent {
        Extent(
            minX: min(minX, other.minX), minY: min(minY, other.minY),
            maxX: max(maxX, other.maxX), maxY: max(maxY, other.maxY)
        )
    }

    func intersects(_ other: Extent) -> Bool {
        min(maxX, other.maxX) > max(minX, other.minX) && min(maxY, other.maxY) > max(minY, other.minY)
    }
}
