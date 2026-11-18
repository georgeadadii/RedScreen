import CoreGraphics
import CoreText
import CryptoKit
import Foundation
import ImageIO

// Renders synthetic fixture scenarios into PNG data and computes their ground truth.
//
// This file is shared by the test bundle and the standalone generator. It performs no file or
// network I/O and reads no process state: its only inputs are the compiled-in scenarios.

enum FixtureRenderError: Error, Equatable, CustomStringConvertible {
    case fontUnavailable(String)
    case invalidScale(Int)
    case invalidCanvasWidth(scenario: String)
    case emptyRun(scenario: String, row: Int)
    case textOverflow(scenario: String, row: Int)
    case overlappingText(scenario: String, row: Int)
    case inconsistentSpan(scenario: String, spanID: String)
    case bitmapContextUnavailable
    case pngEncodingFailed

    var description: String {
        switch self {
        case .fontUnavailable(let name): "Required font \(name) is unavailable"
        case .invalidScale(let scale): "Unsupported scale \(scale)"
        case .invalidCanvasWidth(let scenario): "\(scenario): canvas width must be integral"
        case .emptyRun(let scenario, let row): "\(scenario): empty run on row \(row)"
        case .textOverflow(let scenario, let row): "\(scenario): text overflows on row \(row)"
        case .overlappingText(let scenario, let row): "\(scenario): text overlaps on row \(row)"
        case .inconsistentSpan(let scenario, let spanID):
            "\(scenario): span \(spanID) has inconsistent labels"
        case .bitmapContextUnavailable: "Could not create bitmap context"
        case .pngEncodingFailed: "Could not encode PNG"
        }
    }
}

struct RenderedFixture {
    let groundTruth: FixtureGroundTruth
    let png: Data
}

struct FixtureRenderer {
    static let padding = 20.0
    static let geometryPrecision = 1e6

    func fixtureID(for scenario: FixtureScenario, scale: Int) -> String {
        "\(scenario.name)-\(scale)x"
    }

    func groundTruth(for scenario: FixtureScenario, scale: Int) throws -> FixtureGroundTruth {
        try layout(scenario, scale: scale).groundTruth
    }

    func render(_ scenario: FixtureScenario, scale: Int) throws -> RenderedFixture {
        let layout = try layout(scenario, scale: scale)
        let palette = scenario.theme.palette
        let pixelWidth = layout.groundTruth.pixelWidth
        let pixelHeight = layout.groundTruth.pixelHeight

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: pixelWidth,
                  height: pixelHeight,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw FixtureRenderError.bitmapContextUnavailable
        }

        // Grayscale antialiasing only: subpixel smoothing varies with display settings.
        context.setShouldAntialias(true)
        context.setAllowsFontSmoothing(false)
        context.setShouldSmoothFonts(false)
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))

        let canvasWidth = scenario.canvasWidth
        let canvasHeight = layout.canvasHeight
        context.setFillColor(palette.background)
        context.fill(CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))

        context.setFillColor(palette.stripe)
        for row in scenario.stripedRows {
            let top = Self.padding + Double(row) * layout.lineHeight
            context.fill(CGRect(
                x: Self.padding / 2,
                y: canvasHeight - top - layout.lineHeight,
                width: canvasWidth - Self.padding,
                height: layout.lineHeight
            ))
        }

        context.textMatrix = .identity
        for block in layout.blocks {
            context.textPosition = CGPoint(x: block.originX, y: canvasHeight - block.baselineY)
            CTLineDraw(block.line, context)
        }

        guard let image = context.makeImage() else {
            throw FixtureRenderError.bitmapContextUnavailable
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            "public.png" as CFString,
            1,
            nil
        ) else {
            throw FixtureRenderError.pngEncodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw FixtureRenderError.pngEncodingFailed
        }
        return RenderedFixture(groundTruth: layout.groundTruth, png: data as Data)
    }

    // MARK: - Layout

    private struct LaidOutBlock {
        let line: CTLine
        let originX: Double
        let baselineY: Double
    }

    private struct Layout {
        let groundTruth: FixtureGroundTruth
        let blocks: [LaidOutBlock]
        let canvasHeight: Double
        let lineHeight: Double
    }

    private func layout(_ scenario: FixtureScenario, scale: Int) throws -> Layout {
        guard scale == 1 || scale == 2 else { throw FixtureRenderError.invalidScale(scale) }
        guard scenario.canvasWidth == scenario.canvasWidth.rounded(), scenario.canvasWidth > 0
        else {
            throw FixtureRenderError.invalidCanvasWidth(scenario: scenario.name)
        }

        let font = try makeFont(scenario.fontStyle)
        let ascent = Double(CTFontGetAscent(font))
        let descent = Double(CTFontGetDescent(font))
        let lineHeight = (Double(CTFontGetSize(font)) * 1.7).rounded()
        let canvasWidth = scenario.canvasWidth
        let canvasHeight = Self.padding * 2 + Double(scenario.rowCount) * lineHeight
        let foreground = scenario.theme.palette.foreground

        var textBoxes: [FixtureTextBox] = []
        var laidOut: [LaidOutBlock] = []
        var spanOrder: [String] = []
        var spanMarks: [String: FixtureSpanMark] = [:]
        var spanSegments: [String: [FixtureSpanSegment]] = [:]
        var rowExtents: [Int: [(minX: Double, maxX: Double)]] = [:]

        for (index, block) in scenario.blocks.enumerated() {
            guard block.runs.allSatisfy({ !$0.text.isEmpty }) else {
                throw FixtureRenderError.emptyRun(scenario: scenario.name, row: block.row)
            }
            let text = block.runs.map(\.text).joined()
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): foreground,
                NSAttributedString.Key(kCTLigatureAttributeName as String): 0,
            ]
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: text, attributes: attributes)
            )
            let width = Double(CTLineGetTypographicBounds(line, nil, nil, nil))
            let originX = Self.padding + block.x
            // The text box covers visible text only: leading and trailing whitespace is excluded
            // from its geometry, though it stays in `text` so offsets are unchanged.
            guard let firstInk = text.utf16.firstIndex(where: { !Self.isSpace($0) }),
                  let lastInk = text.utf16.lastIndex(where: { !Self.isSpace($0) }) else {
                throw FixtureRenderError.emptyRun(scenario: scenario.name, row: block.row)
            }
            let inkStart = Double(CTLineGetOffsetForStringIndex(
                line, text.utf16.distance(from: text.utf16.startIndex, to: firstInk), nil
            ))
            let inkEnd = Double(CTLineGetOffsetForStringIndex(
                line, text.utf16.distance(from: text.utf16.startIndex, to: lastInk) + 1, nil
            ))
            let top = Self.padding + Double(block.row) * lineHeight
            let baselineY = top + (lineHeight - (ascent + descent)) / 2 + ascent
            let boxY = baselineY - ascent
            let boxHeight = ascent + descent

            guard originX + width <= canvasWidth - Self.padding else {
                throw FixtureRenderError.textOverflow(scenario: scenario.name, row: block.row)
            }
            rowExtents[block.row, default: []].append((originX, originX + width))

            let textBoxID = String(format: "t%02d", index)
            textBoxes.append(FixtureTextBox(
                id: textBoxID,
                text: text,
                rect: normalized(
                    x: originX + inkStart, y: boxY, width: inkEnd - inkStart, height: boxHeight,
                    canvasWidth: canvasWidth, canvasHeight: canvasHeight
                )
            ))
            laidOut.append(LaidOutBlock(line: line, originX: originX, baselineY: baselineY))

            var utf16Offset = 0
            for run in block.runs {
                let length = run.text.utf16.count
                defer { utf16Offset += length }
                guard let mark = run.mark else { continue }

                if let existing = spanMarks[mark.id] {
                    guard existing == mark else {
                        throw FixtureRenderError.inconsistentSpan(
                            scenario: scenario.name, spanID: mark.id
                        )
                    }
                } else {
                    spanMarks[mark.id] = mark
                    spanOrder.append(mark.id)
                }

                let startX = Double(CTLineGetOffsetForStringIndex(line, utf16Offset, nil))
                let endX = Double(CTLineGetOffsetForStringIndex(line, utf16Offset + length, nil))
                spanSegments[mark.id, default: []].append(FixtureSpanSegment(
                    textBoxID: textBoxID,
                    utf16Offset: utf16Offset,
                    utf16Length: length,
                    rect: normalized(
                        x: originX + startX, y: boxY, width: endX - startX, height: boxHeight,
                        canvasWidth: canvasWidth, canvasHeight: canvasHeight
                    )
                ))
            }
        }

        for (row, extents) in rowExtents {
            let sorted = extents.sorted { $0.minX < $1.minX }
            for (left, right) in zip(sorted, sorted.dropFirst()) where left.maxX > right.minX {
                throw FixtureRenderError.overlappingText(scenario: scenario.name, row: row)
            }
        }

        let spans = spanOrder.map { id in
            let mark = spanMarks[id]!
            return FixtureSpan(
                id: id,
                family: mark.family,
                expectation: mark.expectation,
                note: mark.note,
                segments: spanSegments[id] ?? []
            )
        }

        let groundTruth = FixtureGroundTruth(
            schemaVersion: FixtureSchema.version,
            id: fixtureID(for: scenario, scale: scale),
            scenario: scenario.description,
            syntheticTestData: true,
            category: scenario.category,
            theme: scenario.theme,
            fontStyle: scenario.fontStyle,
            scale: scale,
            difficulties: scenario.difficulties,
            pixelWidth: Int(canvasWidth) * scale,
            pixelHeight: Int(canvasHeight) * scale,
            coordinateSpace: FixtureSchema.coordinateSpace,
            textBoxes: textBoxes,
            spans: spans
        )
        return Layout(
            groundTruth: groundTruth,
            blocks: laidOut,
            canvasHeight: canvasHeight,
            lineHeight: lineHeight
        )
    }

    private static func isSpace(_ unit: UTF16.CodeUnit) -> Bool {
        unit == 0x20 || unit == 0x09
    }

    private func makeFont(_ style: FixtureFontStyle) throws -> CTFont {
        let (name, size): (String, CGFloat) = switch style {
        case .monospace: ("Menlo-Regular", 13)
        case .proportional: ("Helvetica", 14)
        }
        let font = CTFontCreateWithName(name as CFString, size, nil)
        // Core Text silently substitutes missing fonts; refuse rather than drift.
        guard CTFontCopyPostScriptName(font) as String == name else {
            throw FixtureRenderError.fontUnavailable(name)
        }
        return font
    }

    private func normalized(
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        canvasWidth: Double,
        canvasHeight: Double
    ) -> FixtureRect {
        func round(_ value: Double) -> Double {
            (value * Self.geometryPrecision).rounded() / Self.geometryPrecision
        }
        return FixtureRect(
            x: round(x / canvasWidth),
            y: round(y / canvasHeight),
            width: round(width / canvasWidth),
            height: round(height / canvasHeight)
        )
    }
}

private struct FixturePalette {
    let background: CGColor
    let foreground: CGColor
    let stripe: CGColor
}

private extension FixtureTheme {
    var palette: FixturePalette {
        func color(_ hex: UInt32) -> CGColor {
            CGColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        }
        return switch self {
        case .light:
            FixturePalette(
                background: color(0xFFFFFF), foreground: color(0x1F2328), stripe: color(0xF0F2F5)
            )
        case .dark:
            FixturePalette(
                background: color(0x1E1E1E), foreground: color(0xD4D4D4), stripe: color(0x2A2D31)
            )
        case .lowContrast:
            FixturePalette(
                background: color(0xEDEDED), foreground: color(0x9A9A9A), stripe: color(0xE4E4E4)
            )
        }
    }
}

enum FixtureDigest {
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
