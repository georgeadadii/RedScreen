import Foundation

/// Finds where each character of an OCR word or line sits, by measuring the image (issue #8).
///
/// Vision only reports word-level boxes, so the boundary between `KEY=` and `value` inside one
/// word cannot come from OCR. Code editors and terminals, where `.env` files and shell exports
/// are shown, use fixed-width fonts: every character occupies one cell of the same width. The
/// locator fits that cell grid to the ink in the box:
///
/// 1. Classify pixels as ink or background (the region's dominant colour), using the upper ~78%
///    of the line so underscores and descenders, which bridge neighbouring cells, are ignored.
/// 2. Find the word's actual ink extent, extending past Vision's box while ink continues (Vision
///    boxes can be slightly narrower than the glyphs).
/// 3. Search cell widths and origins for the grid whose cell boundaries fall on the emptiest
///    columns, with the last glyph inside the last cell.
/// 4. Accept the grid only if its boundaries are clearly emptier than the glyphs themselves.
///    Proportional text, wide characters, or noise fail this test, and callers then cover the
///    whole word instead of guessing.
struct GlyphGridLocator {
    struct Grid: Equatable {
        /// Left edge of the first character cell, in image pixels.
        let origin: Double
        /// Cell width, in image pixels.
        let pitch: Double
        /// Inclusive first and exclusive last ink columns of the measured word.
        let inkStart: Double
        let inkEnd: Double

        func edge(_ cell: Int) -> Double { origin + Double(cell) * pitch }
    }

    /// Boundary ink must be below this fraction of the mean ink per column.
    static let maximumBoundaryInkRatio = 0.3
    /// Share of visible characters whose cell may look empty (thin glyphs at the profile's edge).
    static let maximumEmptyCellFraction = 0.1
    /// A run of empty columns at least this many cells wide ends a word.
    static let wordGapCells = 0.75

    let pixels: DecodedPixels
    let layout: PixelBufferLayout

    init?(pixels: DecodedPixels?) {
        guard let pixels, let layout = pixels.layout,
              layout.pixelFormat == .rgba8PremultipliedLast else {
            return nil
        }
        self.pixels = pixels
        self.layout = layout
    }

    /// Ink extent of the word inside `box`, extended past the box edges while ink continues.
    func inkExtent(
        of box: Extent,
        characterCount: Int,
        extendLeft: Bool = true,
        extendRight: Bool = true
    ) -> (start: Double, end: Double)? {
        guard characterCount > 0, box.width > 0 else { return nil }
        let approximatePitch = box.width / Double(characterCount)
        guard let profile = columnProfile(around: box, approximatePitch: approximatePitch) else {
            return nil
        }
        return extent(in: profile, box: box, approximatePitch: approximatePitch,
                      extendLeft: extendLeft, extendRight: extendRight)
    }

    /// Fits a fixed-width cell grid to the `characterCount` characters in `box`.
    ///
    /// `visibleCells` says which characters must draw ink in the measured band (`true`), which
    /// must be blank (`false`, spaces), and which may go either way (`nil`: `_ . ,` sit on or
    /// below the baseline). The grid is anchored on the word's ink: first on its left end, and, if
    /// that fails, on its right end (OCR boxes sometimes start inside a neighbouring glyph,
    /// which spoils the left anchor). A grid is accepted only if:
    /// - its cell boundaries are clearly emptier than the glyphs;
    /// - at most 10% of visible characters have an empty cell;
    /// - no space's cell has ink, except the outermost cell on the unanchored side,
    ///   where a neighbour's glyph may overlap the OCR box.
    /// Anchoring on real ink keeps the grid from shifting by whole characters, which is the
    /// failure that would expose part of a secret.
    func fitGrid(
        box: Extent,
        characterCount: Int,
        visibleCells: [Bool?]? = nil,
        extendLeft: Bool = true,
        extendRight: Bool = true
    ) -> Grid? {
        guard characterCount >= 2, box.width > 0 else { return nil }
        let boxPitch = box.width / Double(characterCount)
        guard boxPitch >= 2,
              let profile = columnProfile(around: box, approximatePitch: boxPitch),
              let ink = extent(in: profile, box: box, approximatePitch: boxPitch,
                               extendLeft: extendLeft, extendRight: extendRight) else {
            return nil
        }
        let visible: [Bool?] = visibleCells ?? Array(repeating: true, count: characterCount)
        guard visible.count == characterCount, visible.contains(true) else { return nil }
        return search(profile: profile, ink: ink, boxPitch: boxPitch, visible: visible, anchorLeft: true)
            ?? search(profile: profile, ink: ink, boxPitch: boxPitch, visible: visible, anchorLeft: false)
    }

    private func search(
        profile: ColumnProfile,
        ink: (start: Double, end: Double),
        boxPitch: Double,
        visible: [Bool?],
        anchorLeft: Bool
    ) -> Grid? {
        let characterCount = visible.count
        let count = Double(characterCount)
        // Left-anchored: the ink width sets the range (side bearings make ink a little narrower
        // than `count` cells). Right-anchored: the left edge is the unreliable one, so the range
        // comes from the OCR box instead.
        let inkPitch = (ink.end - ink.start) / count
        let lowestPitch = anchorLeft ? min(inkPitch, boxPitch) * 0.97 : boxPitch * 0.92
        let highestPitch = anchorLeft
            ? max((ink.end - ink.start) / max(1, count - 0.9), boxPitch * 1.05)
            : boxPitch * 1.08
        let pitchStep = max(0.01, lowestPitch * 0.004)

        var best: (score: Double, grid: Grid)?
        var pitch = lowestPitch
        while pitch <= highestPitch {
            let origins: StrideThrough<Double> = anchorLeft
                ? stride(from: ink.start - pitch * 0.5, through: ink.start, by: 0.25)
                : stride(from: ink.end - count * pitch - pitch * 0.05,
                         through: ink.end - count * pitch + pitch * 0.6, by: 0.25)
            for origin in origins {
                let end = origin + count * pitch
                if anchorLeft, !(end >= ink.end - pitch * 0.05 && end <= ink.end + pitch * 0.6) { continue }
                if !anchorLeft, !(origin <= ink.start + pitch * 0.5) { continue }
                var boundaryInk = 0.0
                for cell in 1..<characterCount {
                    // The emptiest column within half a pixel of the boundary: at 1x,
                    // anti-aliasing smears glyph edges across the exact boundary column.
                    let boundary = origin + Double(cell) * pitch
                    boundaryInk += min(
                        profile.value(at: boundary - 0.5),
                        profile.value(at: boundary),
                        profile.value(at: boundary + 0.5)
                    )
                }
                let score = boundaryInk / Double(characterCount - 1)
                if best == nil || score < best!.score {
                    best = (score, Grid(origin: origin, pitch: pitch, inkStart: ink.start, inkEnd: ink.end))
                }
            }
            pitch += pitchStep
        }
        guard let best else { return nil }
        let grid = best.grid
        let meanInk = profile.mean(from: grid.edge(0), to: grid.edge(characterCount))
        guard meanInk > 0, best.score <= Self.maximumBoundaryInkRatio * meanInk else { return nil }

        var visibleCount = 0
        var emptyVisible = 0
        for cell in 0..<characterCount {
            let cellInk = profile.mean(
                from: grid.edge(cell) + grid.pitch * 0.15, to: grid.edge(cell + 1) - grid.pitch * 0.15
            )
            switch visible[cell] {
            case true?:
                visibleCount += 1
                if cellInk == 0 { emptyVisible += 1 }
            case false? where cellInk > 0.02:
                let overlapCell = anchorLeft ? characterCount - 1 : 0
                guard cell == overlapCell else { return nil }
            default:
                break
            }
        }
        guard Double(emptyVisible) <= Double(visibleCount) * Self.maximumEmptyCellFraction else {
            return nil
        }
        return grid
    }

    // MARK: - Pixels

    /// Fraction of ink pixels per column across the upper part of the line.
    struct ColumnProfile {
        let firstColumn: Int
        let values: [Double]

        func value(at x: Double) -> Double {
            let index = Int(x.rounded(.down)) - firstColumn
            guard index >= 0, index < values.count else { return 0 }
            let fraction = x - x.rounded(.down)
            let next = index + 1 < values.count ? values[index + 1] : values[index]
            return values[index] * (1 - fraction) + next * fraction
        }

        func isInk(_ column: Int) -> Bool {
            let index = column - firstColumn
            return index >= 0 && index < values.count && values[index] > 0
        }

        func mean(from start: Double, to end: Double) -> Double {
            let lower = max(0, Int(start) - firstColumn)
            let upper = min(values.count, Int(end.rounded(.up)) - firstColumn)
            guard upper > lower else { return 0 }
            return values[lower..<upper].reduce(0, +) / Double(upper - lower)
        }
    }

    private func columnProfile(around box: Extent, approximatePitch: Double) -> ColumnProfile? {
        let width = layout.dimensions.width
        let height = layout.dimensions.height
        let left = max(0, Int((box.minX - approximatePitch * 3).rounded(.down)))
        let right = min(width, Int((box.maxX + approximatePitch * 3).rounded(.up)))
        let top = max(0, Int(box.minY.rounded(.down)))
        let bottom = min(height, Int((box.minY + box.height * 0.78).rounded(.up)))
        guard right - left >= 2, bottom - top >= 2 else { return nil }

        let background = dominantColor(left: left, right: right, top: top, bottom: bottom)
        var values = [Double](repeating: 0, count: right - left)
        let rows = Double(bottom - top)
        for x in left..<right {
            var ink = 0
            for y in top..<bottom where distance(color(x: x, y: y), background) > 60 {
                ink += 1
            }
            values[x - left] = Double(ink) / rows
        }
        return ColumnProfile(firstColumn: left, values: values)
    }

    /// First and last ink columns inside the box, extended outward while ink continues.
    /// Extension is skipped on a side where the text continues without a space (for example a
    /// word box that starts right after `DEPLOY_`), so ink from the neighbouring word is not
    /// pulled in across an underscore.
    private func extent(
        in profile: ColumnProfile,
        box: Extent,
        approximatePitch: Double,
        extendLeft: Bool,
        extendRight: Bool
    ) -> (start: Double, end: Double)? {
        let boxStart = Int(box.minX.rounded(.down))
        let boxEnd = Int(box.maxX.rounded(.up))
        guard var start = (boxStart..<boxEnd).first(where: profile.isInk),
              var end = (boxStart..<boxEnd).last(where: profile.isInk) else {
            return nil
        }
        let maximumGap = Int((approximatePitch * Self.wordGapCells).rounded(.up))
        let lastColumn = profile.firstColumn + profile.values.count
        func extend(from column: Int, step: Int) -> Int {
            var current = column
            var probe = column + step
            var gap = 0
            while gap < maximumGap, probe >= profile.firstColumn, probe < lastColumn {
                if profile.isInk(probe) {
                    current = probe
                    gap = 0
                } else {
                    gap += 1
                }
                probe += step
            }
            return current
        }
        if extendLeft { start = extend(from: start, step: -1) }
        if extendRight { end = extend(from: end, step: 1) }
        return (Double(start), Double(end + 1))
    }

    private func dominantColor(left: Int, right: Int, top: Int, bottom: Int) -> (Int, Int, Int) {
        var counts: [Int: Int] = [:]
        for y in stride(from: top, to: bottom, by: 2) {
            for x in stride(from: left, to: right, by: 2) {
                let c = color(x: x, y: y)
                counts[(c.0 >> 3) << 10 | (c.1 >> 3) << 5 | (c.2 >> 3), default: 0] += 1
            }
        }
        guard let key = counts.max(by: { $0.value < $1.value })?.key else { return (0, 0, 0) }
        return ((key >> 10 & 31) << 3 | 4, (key >> 5 & 31) << 3 | 4, (key & 31) << 3 | 4)
    }

    private func color(x: Int, y: Int) -> (Int, Int, Int) {
        let offset = y * layout.bytesPerRow + x * 4
        let bytes = pixels.bytes
        let base = bytes.startIndex + offset
        return (Int(bytes[base]), Int(bytes[base + 1]), Int(bytes[base + 2]))
    }

    private func distance(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Int {
        abs(a.0 - b.0) + abs(a.1 - b.1) + abs(a.2 - b.2)
    }
}
