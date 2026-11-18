import Foundation

/// Tunable geometry for candidate composition.
public struct CandidateCompositionPolicy: Equatable, Sendable {
    /// Padding added at word-boundary and whole-word edges, in image pixels.
    public var minimumPaddingPixels: Double
    /// Vertical padding as a fraction of the line height (the larger of this and the minimum
    /// applies), so padding scales with 1x and 2x screenshots. Kept small so tightly spaced
    /// editor lines above and below are not clipped.
    public var paddingFractionOfLineHeight: Double
    /// Padding at an edge measured inside a word, as a fraction of the character cell width.
    /// Kept small so it never reaches the neighbouring key character.
    public var measuredEdgePaddingFraction: Double

    public static let standard = CandidateCompositionPolicy(
        minimumPaddingPixels: 2,
        paddingFractionOfLineHeight: 0.08,
        measuredEdgePaddingFraction: 0.06
    )

    public init(
        minimumPaddingPixels: Double,
        paddingFractionOfLineHeight: Double,
        measuredEdgePaddingFraction: Double
    ) {
        self.minimumPaddingPixels = minimumPaddingPixels
        self.paddingFractionOfLineHeight = paddingFractionOfLineHeight
        self.measuredEdgePaddingFraction = measuredEdgePaddingFraction
    }
}

/// Turns detector spans into minimal, padded, in-bounds image rectangles (issue #8).
///
/// Each edge of a value is placed by the most precise method available:
/// 1. **Word boundary:** the value starts or ends where an OCR word does. The word box is used,
///    extended to the word's measured ink so a slightly narrow OCR box cannot clip glyphs.
/// 2. **Measured:** the edge falls inside an OCR word (`KEY=value`, `KEY="value with spaces"`).
///    `GlyphGridLocator` fits the fixed-width character grid to the pixels and the edge is placed
///    on the exact cell boundary.
/// 3. **Whole-word fallback:** if no pixels are available or the grid does not fit confidently
///    (for example proportional text), the whole OCR word is covered, key included, and the
///    candidate is flagged for review. Exposing part of a secret is never an acceptable outcome.
///
/// Private key blocks are covered as one rectangle spanning the whole block. Rectangles are
/// padded, clamped to the image, and checked for finiteness and positive size. Findings merge
/// into one candidate (with combined evidence) only when their rectangles overlap **on the same
/// line**; rectangles on different lines are never joined. Output is sorted in reading order.
/// Likely findings start `included`; findings needing review start `pending`. No matched text is
/// copied into candidates.
public struct GeometricCandidateComposer: CandidateComposer {
    public let policy: CandidateCompositionPolicy

    public init(policy: CandidateCompositionPolicy = .standard) {
        self.policy = policy
    }

    public func composeCandidates(
        from detections: [SecretDetection],
        observations: [OCRObservation],
        pixels: DecodedPixels?,
        dimensions: PixelDimensions
    ) throws -> [RedactionCandidate] {
        let byID = Dictionary(uniqueKeysWithValues: observations.map { ($0.id, $0) })
        let locator = GlyphGridLocator(pixels: pixels).flatMap {
            $0.layout.dimensions == dimensions ? $0 : nil
        }
        var drafts: [Draft] = []
        for detection in detections {
            var rects: [ImageRect] = []
            var geometry = CandidateGeometry.wordAligned
            for span in detection.spans {
                guard let observation = byID[span.observationID] else {
                    throw DomainModelError.unknownObservation
                }
                let placed = try place(span, in: observation, dimensions: dimensions, locator: locator)
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

    /// A box and the text range it covers: an OCR word, or the whole line without word boxes.
    private struct Unit {
        let box: Extent
        let range: Range<Int>
    }

    private struct Edge {
        let x: Double
        let geometry: CandidateGeometry
        let padding: Double
    }

    func place(
        _ span: DetectedTextSpan,
        in observation: OCRObservation,
        dimensions: PixelDimensions,
        locator: GlyphGridLocator?
    ) throws -> Placement {
        let line = Extent(try observation.imageRect(in: dimensions))
        let text = observation.text
        let utf16Count = text.utf16.count
        let range = max(0, span.utf16Range.lowerBound)..<min(utf16Count, span.utf16Range.upperBound)
        let offsets = characterOffsets(in: text)

        var units = try wordUnits(of: observation, line: line, dimensions: dimensions)
            .filter { $0.range.overlaps(range) }
        if units.isEmpty, let ink = inkRange(of: text) {
            units = [Unit(box: line, range: ink)]
        }
        guard !range.isEmpty, let first = units.first, let last = units.last else {
            return Placement(
                rect: try padded(line, left: policy.minimumPaddingPixels, right: policy.minimumPaddingPixels,
                                 dimensions: dimensions),
                geometry: .lineFallback
            )
        }

        let start = edge(of: range.lowerBound, in: first, leading: true, text: text, offsets: offsets, locator: locator)
        let end = edge(of: range.upperBound, in: last, leading: false, text: text, offsets: offsets, locator: locator)
        let top = units.map(\.box.minY).min() ?? line.minY
        let bottom = units.map(\.box.maxY).max() ?? line.maxY
        guard end.x > start.x else {
            let whole = units.dropFirst().reduce(first.box) { $0.union($1.box) }
            return Placement(
                rect: try padded(whole, left: policy.minimumPaddingPixels, right: policy.minimumPaddingPixels,
                                 dimensions: dimensions),
                geometry: .lineFallback
            )
        }
        let extent = Extent(minX: start.x, minY: top, maxX: end.x, maxY: bottom)
        return Placement(
            rect: try padded(extent, left: start.padding, right: end.padding, dimensions: dimensions),
            geometry: max(start.geometry, end.geometry)
        )
    }

    /// The observation's word boxes, plus synthesized units for any visible text Vision did not
    /// box (its sub-range lookup occasionally fails for a word). A gap unit spans from the
    /// previous word box to the next one, or to the end of the line.
    private func wordUnits(
        of observation: OCRObservation,
        line: Extent,
        dimensions: PixelDimensions
    ) throws -> [Unit] {
        let text = Array(observation.text.utf16)
        let words = try observation.segments
            .sorted { $0.utf16Range.lowerBound < $1.utf16Range.lowerBound }
            .map { Unit(box: Extent(try observation.imageRect(for: $0, in: dimensions)), range: $0.utf16Range) }
        guard !words.isEmpty else { return [] }

        func isSpace(_ index: Int) -> Bool { text[index] == 0x20 || text[index] == 0x09 }
        func trimmed(_ range: Range<Int>) -> Range<Int>? {
            var lower = range.lowerBound
            var upper = range.upperBound
            while lower < upper, isSpace(lower) { lower += 1 }
            while upper > lower, isSpace(upper - 1) { upper -= 1 }
            return lower < upper ? lower..<upper : nil
        }

        var units: [Unit] = []
        var cursor = 0
        var previousRight = line.minX
        for word in words + [nil] as [Unit?] {
            let gapEnd = word?.range.lowerBound ?? text.count
            if gapEnd > cursor, let gap = trimmed(cursor..<gapEnd) {
                let right = word?.box.minX ?? line.maxX
                if right > previousRight {
                    units.append(Unit(
                        box: Extent(minX: previousRight, minY: line.minY, maxX: right, maxY: line.maxY),
                        range: gap
                    ))
                }
            }
            if let word {
                units.append(word)
                cursor = max(cursor, word.range.upperBound)
                previousRight = max(previousRight, word.box.maxX)
            }
        }
        return units
    }

    /// Places one edge of the value: on a word boundary, on a measured character cell, or at the
    /// word's outer edge when measurement is not possible.
    private func edge(
        of offset: Int,
        in unit: Unit,
        leading: Bool,
        text: String,
        offsets: [Int],
        locator: GlyphGridLocator?
    ) -> Edge {
        let characters = characterIndex(unit.range.upperBound, offsets) - characterIndex(unit.range.lowerBound, offsets)
        // Only grow past the box where the text has a space (or the line ends) on that side.
        let utf16 = Array(text.utf16)
        func isBreak(_ index: Int) -> Bool {
            index < 0 || index >= utf16.count || utf16[index] == 0x20 || utf16[index] == 0x09
        }
        let extendLeft = isBreak(unit.range.lowerBound - 1)
        let extendRight = isBreak(unit.range.upperBound)
        let ink = locator?.inkExtent(
            of: unit.box, characterCount: max(1, characters),
            extendLeft: extendLeft, extendRight: extendRight
        )
        let outer = leading ? min(unit.box.minX, ink?.start ?? unit.box.minX)
                            : max(unit.box.maxX, ink?.end ?? unit.box.maxX)
        let onBoundary = leading ? offset <= unit.range.lowerBound : offset >= unit.range.upperBound
        if onBoundary {
            return Edge(x: outer, geometry: .wordAligned, padding: policy.minimumPaddingPixels)
        }
        let firstCharacter = characterIndex(unit.range.lowerBound, offsets)
        // Spaces must be blank; `_ . ,` sit at or below the baseline and may or may not show in
        // the measured band; everything else must draw ink.
        let visible = (0..<characters).map { index -> Bool? in
            let start = offsets[firstCharacter + index]
            let end = offsets[firstCharacter + index + 1]
            let units = Array(text.utf16)[start..<min(end, text.utf16.count)]
            if units.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) { return false }
            if units.allSatisfy({ $0 == 0x5F || $0 == 0x2E || $0 == 0x2C }) { return nil }
            return true
        }
        guard let grid = locator?.fitGrid(
            box: unit.box, characterCount: characters, visibleCells: visible,
            extendLeft: extendLeft, extendRight: extendRight
        ) else {
            return Edge(x: outer, geometry: .lineFallback, padding: policy.minimumPaddingPixels)
        }
        let cell = characterIndex(offset, offsets) - characterIndex(unit.range.lowerBound, offsets)
        return Edge(
            x: grid.edge(cell),
            geometry: .measured,
            padding: max(0.5, grid.pitch * policy.measuredEdgePaddingFraction)
        )
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

    /// Index of the first character boundary at or after a UTF-16 offset.
    private func characterIndex(_ utf16Offset: Int, _ offsets: [Int]) -> Int {
        offsets.firstIndex { $0 >= utf16Offset } ?? offsets.count - 1
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
        left: Double,
        right: Double,
        dimensions: PixelDimensions
    ) throws -> ImageRect {
        let vertical = max(policy.minimumPaddingPixels, extent.height * policy.paddingFractionOfLineHeight)
        let minX = max(0, extent.minX - left)
        let minY = max(0, extent.minY - vertical)
        let maxX = min(Double(dimensions.width), extent.maxX + right)
        let maxY = min(Double(dimensions.height), extent.maxY + vertical)
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

        /// Overlap on the same line only: padded rectangles on adjacent lines can touch, but they
        /// belong to different values and must never be joined.
        func overlaps(_ other: Draft) -> Bool {
            rects.contains { left in other.rects.contains { Extent(left).overlapsOnSameLine(Extent($0)) } }
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
                for j in extents.indices where j > i && extents[i].overlapsOnSameLine(extents[j]) {
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

    /// Intersecting, with vertical overlap of at least half the shorter height.
    func overlapsOnSameLine(_ other: Extent) -> Bool {
        let vertical = min(maxY, other.maxY) - max(minY, other.minY)
        return intersects(other) && vertical >= 0.5 * min(height, other.height)
    }
}
