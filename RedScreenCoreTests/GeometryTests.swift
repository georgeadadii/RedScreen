import XCTest

@testable import RedScreenCore

final class GeometryTests: XCTestCase {
    func testTopLeftNormalizedRectConvertsToLandscapeImagePixels() throws {
        let dimensions = try PixelDimensions(width: 1_920, height: 1_080)
        let normalized = try NormalizedRect(x: 0.25, y: 0.1, width: 0.5, height: 0.25)

        let result = try ImageRect(
            normalized: normalized,
            dimensions: dimensions,
            sourceOrigin: .topLeft
        )

        XCTAssertEqual(result.x, 480, accuracy: 1e-9)
        XCTAssertEqual(result.y, 108, accuracy: 1e-9)
        XCTAssertEqual(result.width, 960, accuracy: 1e-9)
        XCTAssertEqual(result.height, 270, accuracy: 1e-9)
    }

    func testBottomLeftNormalizedRectFlipsIntoPortraitImagePixels() throws {
        let dimensions = try PixelDimensions(width: 1_000, height: 2_000)
        let normalized = try NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)

        let result = try ImageRect(
            normalized: normalized,
            dimensions: dimensions,
            sourceOrigin: .bottomLeft
        )

        XCTAssertEqual(result.x, 100, accuracy: 1e-9)
        XCTAssertEqual(result.y, 800, accuracy: 1e-9)
        XCTAssertEqual(result.width, 300, accuracy: 1e-9)
        XCTAssertEqual(result.height, 800, accuracy: 1e-9)
    }

    func testNormalizedImageRoundTripsForBothOriginsAndOrientations() throws {
        let dimensions = [
            try PixelDimensions(width: 800, height: 1_200),
            try PixelDimensions(width: 1_600, height: 900)
        ]
        let origins: [NormalizedCoordinateOrigin] = [.topLeft, .bottomLeft]
        let source = try NormalizedRect(x: 0.123, y: 0.234, width: 0.345, height: 0.321)

        for dimensions in dimensions {
            for origin in origins {
                let image = try ImageRect(
                    normalized: source,
                    dimensions: dimensions,
                    sourceOrigin: origin
                )
                let roundTrip = try image.normalized(in: dimensions, targetOrigin: origin)

                assertEqual(roundTrip, source, accuracy: 1e-12)
            }
        }
    }

    func testEnclosingPixelRectRoundsOutward() throws {
        let dimensions = try PixelDimensions(width: 100, height: 80)
        let imageRect = try ImageRect(x: 10.9, y: 20.1, width: 30.2, height: 10.01)

        let pixels = try imageRect.enclosingPixelRect(in: dimensions)

        XCTAssertEqual(pixels.x, 10)
        XCTAssertEqual(pixels.y, 20)
        XCTAssertEqual(pixels.width, 32)
        XCTAssertEqual(pixels.height, 11)
    }

    func testFullImageBoundaryRemainsWithinPixelDimensions() throws {
        let dimensions = try PixelDimensions(width: 17, height: 23)
        let fullImage = try ImageRect(
            normalized: NormalizedRect(x: 0, y: 0, width: 1, height: 1),
            dimensions: dimensions,
            sourceOrigin: .bottomLeft
        )

        XCTAssertEqual(
            try fullImage.enclosingPixelRect(in: dimensions),
            try PixelRect(x: 0, y: 0, width: 17, height: 23, dimensions: dimensions)
        )
    }

    func testDecimalNormalizedEdgesAtOneAreAcceptedAndClamped() throws {
        let rect = try NormalizedRect(x: 0.8, y: 0.7, width: 0.2, height: 0.3)
        let dimensions = try PixelDimensions(width: 100, height: 100)

        let imageRect = try ImageRect(
            normalized: rect,
            dimensions: dimensions,
            sourceOrigin: .topLeft
        )

        XCTAssertEqual(imageRect.maxX, 100, accuracy: 1e-9)
        XCTAssertEqual(imageRect.maxY, 100, accuracy: 1e-9)
        XCTAssertEqual(
            try imageRect.enclosingPixelRect(in: dimensions),
            try PixelRect(x: 80, y: 70, width: 20, height: 30, dimensions: dimensions)
        )
    }

    func testAspectFitRoundTripAtNonIntegerDisplayScale() throws {
        let dimensions = try PixelDimensions(width: 1_920, height: 1_080)
        let viewSize = try PresentationSize(width: 333, height: 271)
        let transform = AspectFitGeometry(
            imageDimensions: dimensions,
            presentationSize: viewSize
        )
        let source = try ImageRect(x: 101.25, y: 53.75, width: 777.5, height: 412.125)

        let presentation = try transform.presentationRect(for: source)
        let roundTrip = try transform.imageRect(for: presentation)

        XCTAssertEqual(transform.horizontalInset, 0, accuracy: 1e-12)
        XCTAssertGreaterThan(transform.verticalInset, 0)
        assertEqual(roundTrip, source, accuracy: 1e-9)
    }

    func testAspectFitRejectsRectInLetterboxArea() throws {
        let transform = AspectFitGeometry(
            imageDimensions: try PixelDimensions(width: 1_600, height: 900),
            presentationSize: try PresentationSize(width: 400, height: 400)
        )
        let letterboxRect = try PresentationRect(x: 10, y: 10, width: 20, height: 20)

        XCTAssertThrowsError(try transform.imageRect(for: letterboxRect)) {
            XCTAssertEqual($0 as? GeometryError, .presentationRectOutOfBounds)
        }
    }

    func testInvalidDimensionsAndRectInputsAreRejected() throws {
        XCTAssertThrowsError(try PixelDimensions(width: 0, height: 10)) {
            XCTAssertEqual($0 as? GeometryError, .nonPositiveSize)
        }
        XCTAssertThrowsError(try NormalizedRect(x: -.zero, y: 0, width: 0, height: 1)) {
            XCTAssertEqual($0 as? GeometryError, .nonPositiveSize)
        }
        XCTAssertThrowsError(try NormalizedRect(x: -0.1, y: 0, width: 0.2, height: 0.2)) {
            XCTAssertEqual($0 as? GeometryError, .negativeOrigin)
        }
        XCTAssertThrowsError(try NormalizedRect(x: 0.9, y: 0, width: 0.2, height: 0.2)) {
            XCTAssertEqual($0 as? GeometryError, .normalizedRectOutOfBounds)
        }
        XCTAssertThrowsError(try NormalizedRect(x: .nan, y: 0, width: 0.2, height: 0.2)) {
            XCTAssertEqual($0 as? GeometryError, .nonFiniteValue)
        }
        XCTAssertThrowsError(try ImageRect(x: 0, y: 0, width: .infinity, height: 1)) {
            XCTAssertEqual($0 as? GeometryError, .nonFiniteValue)
        }
    }

    func testOutOfBoundsImageRectCannotBeRasterized() throws {
        let dimensions = try PixelDimensions(width: 10, height: 10)
        let imageRect = try ImageRect(x: 9, y: 9, width: 2, height: 2)

        XCTAssertThrowsError(try imageRect.enclosingPixelRect(in: dimensions)) {
            XCTAssertEqual($0 as? GeometryError, .imageRectOutOfBounds)
        }
    }

    private func assertEqual(
        _ lhs: NormalizedRect,
        _ rhs: NormalizedRect,
        accuracy: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(lhs.x, rhs.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(lhs.y, rhs.y, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(lhs.width, rhs.width, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(lhs.height, rhs.height, accuracy: accuracy, file: file, line: line)
    }

    private func assertEqual(
        _ lhs: ImageRect,
        _ rhs: ImageRect,
        accuracy: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(lhs.x, rhs.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(lhs.y, rhs.y, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(lhs.width, rhs.width, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(lhs.height, rhs.height, accuracy: accuracy, file: file, line: line)
    }
}
