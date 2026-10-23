import Foundation

public enum GeometryError: Error, Equatable, Sendable {
    case nonFiniteValue
    case nonPositiveSize
    case negativeOrigin
    case normalizedRectOutOfBounds
    case imageRectOutOfBounds
    case presentationRectOutOfBounds
}

/// Upright image dimensions in physical pixels after orientation normalization.
public struct PixelDimensions: Equatable, Hashable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) throws {
        guard width > 0, height > 0 else { throw GeometryError.nonPositiveSize }
        self.width = width
        self.height = height
    }
}

/// The origin used by a normalized coordinate producer.
public enum NormalizedCoordinateOrigin: Equatable, Sendable {
    case topLeft
    case bottomLeft
}

/// A unit rectangle whose values are finite and contained in the closed `[0, 1]` image bounds.
///
/// The rectangle itself is origin-neutral. Callers specify the producer's origin when converting
/// it to the canonical image coordinate space.
public struct NormalizedRect: Equatable, Hashable, Sendable {
    private static let boundaryTolerance = 1e-12

    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) throws {
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite else {
            throw GeometryError.nonFiniteValue
        }
        guard width > 0, height > 0 else { throw GeometryError.nonPositiveSize }
        guard x >= 0, y >= 0 else { throw GeometryError.negativeOrigin }
        guard x < 1,
              y < 1,
              x + width <= 1 + Self.boundaryTolerance,
              y + height <= 1 + Self.boundaryTolerance else {
            throw GeometryError.normalizedRectOutOfBounds
        }
        self.x = x
        self.y = y
        self.width = min(width, 1 - x)
        self.height = min(height, 1 - y)
    }
}

/// A continuous rectangle in the canonical image-processing coordinate space.
///
/// Units are physical pixels, the origin is the top-left of the orientation-normalized image,
/// `x` increases rightward, and `y` increases downward. Continuous edges are retained until the
/// renderer requests an enclosing integer `PixelRect`.
public struct ImageRect: Equatable, Hashable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }

    public init(x: Double, y: Double, width: Double, height: Double) throws {
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite else {
            throw GeometryError.nonFiniteValue
        }
        guard width > 0, height > 0 else { throw GeometryError.nonPositiveSize }
        guard x >= 0, y >= 0 else { throw GeometryError.negativeOrigin }
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(
        normalized rect: NormalizedRect,
        dimensions: PixelDimensions,
        sourceOrigin: NormalizedCoordinateOrigin
    ) throws {
        let topLeftY: Double
        switch sourceOrigin {
        case .topLeft:
            topLeftY = rect.y
        case .bottomLeft:
            topLeftY = 1 - rect.y - rect.height
        }

        try self.init(
            x: rect.x * Double(dimensions.width),
            y: topLeftY * Double(dimensions.height),
            width: rect.width * Double(dimensions.width),
            height: rect.height * Double(dimensions.height)
        )
    }

    public func normalized(
        in dimensions: PixelDimensions,
        targetOrigin: NormalizedCoordinateOrigin
    ) throws -> NormalizedRect {
        guard isContained(in: dimensions) else { throw GeometryError.imageRectOutOfBounds }
        let normalizedHeight = height / Double(dimensions.height)
        let topLeftY = y / Double(dimensions.height)
        let targetY: Double
        switch targetOrigin {
        case .topLeft:
            targetY = topLeftY
        case .bottomLeft:
            targetY = 1 - topLeftY - normalizedHeight
        }
        return try NormalizedRect(
            x: x / Double(dimensions.width),
            y: targetY,
            width: width / Double(dimensions.width),
            height: normalizedHeight
        )
    }

    public func isContained(in dimensions: PixelDimensions) -> Bool {
        maxX <= Double(dimensions.width) + 1e-9
            && maxY <= Double(dimensions.height) + 1e-9
    }

    /// Returns integer pixel coverage by rounding minimum edges down and maximum edges up.
    public func enclosingPixelRect(in dimensions: PixelDimensions) throws -> PixelRect {
        guard isContained(in: dimensions) else { throw GeometryError.imageRectOutOfBounds }
        let minimumX = max(0, Int(floor(x)))
        let minimumY = max(0, Int(floor(y)))
        let maximumX = min(dimensions.width, Int(ceil(maxX)))
        let maximumY = min(dimensions.height, Int(ceil(maxY)))
        return try PixelRect(
            x: minimumX,
            y: minimumY,
            width: maximumX - minimumX,
            height: maximumY - minimumY,
            dimensions: dimensions
        )
    }
}

/// Integer pixel coverage using half-open edges: `[x, x + width) × [y, y + height)`.
public struct PixelRect: Equatable, Hashable, Sendable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int, dimensions: PixelDimensions) throws {
        guard width > 0, height > 0 else { throw GeometryError.nonPositiveSize }
        guard x >= 0, y >= 0 else { throw GeometryError.negativeOrigin }
        guard x <= dimensions.width - width, y <= dimensions.height - height else {
            throw GeometryError.imageRectOutOfBounds
        }
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var imageRect: ImageRect {
        // Values already passed integer validation, so this construction cannot fail.
        try! ImageRect(
            x: Double(x),
            y: Double(y),
            width: Double(width),
            height: Double(height)
        )
    }
}

/// Framework-neutral view size in presentation points. This is not image-processing geometry.
public struct PresentationSize: Equatable, Hashable, Sendable {
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) throws {
        guard width.isFinite, height.isFinite else { throw GeometryError.nonFiniteValue }
        guard width > 0, height > 0 else { throw GeometryError.nonPositiveSize }
        self.width = width
        self.height = height
    }
}

/// Framework-neutral top-left view rectangle in presentation points.
public struct PresentationRect: Equatable, Hashable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }

    public init(x: Double, y: Double, width: Double, height: Double) throws {
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite else {
            throw GeometryError.nonFiniteValue
        }
        guard width > 0, height > 0 else { throw GeometryError.nonPositiveSize }
        guard x >= 0, y >= 0 else { throw GeometryError.negativeOrigin }
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Reversible aspect-fit mapping between canonical image pixels and presentation points.
public struct AspectFitGeometry: Equatable, Sendable {
    public let imageDimensions: PixelDimensions
    public let presentationSize: PresentationSize
    public let scale: Double
    public let horizontalInset: Double
    public let verticalInset: Double

    public init(imageDimensions: PixelDimensions, presentationSize: PresentationSize) {
        self.imageDimensions = imageDimensions
        self.presentationSize = presentationSize
        scale = min(
            presentationSize.width / Double(imageDimensions.width),
            presentationSize.height / Double(imageDimensions.height)
        )
        horizontalInset = (presentationSize.width - Double(imageDimensions.width) * scale) / 2
        verticalInset = (presentationSize.height - Double(imageDimensions.height) * scale) / 2
    }

    public func presentationRect(for imageRect: ImageRect) throws -> PresentationRect {
        guard imageRect.isContained(in: imageDimensions) else {
            throw GeometryError.imageRectOutOfBounds
        }
        return try PresentationRect(
            x: horizontalInset + imageRect.x * scale,
            y: verticalInset + imageRect.y * scale,
            width: imageRect.width * scale,
            height: imageRect.height * scale
        )
    }

    public func imageRect(for presentationRect: PresentationRect) throws -> ImageRect {
        let contentMaximumX = horizontalInset + Double(imageDimensions.width) * scale
        let contentMaximumY = verticalInset + Double(imageDimensions.height) * scale
        guard presentationRect.x >= horizontalInset,
              presentationRect.y >= verticalInset,
              presentationRect.maxX <= contentMaximumX,
              presentationRect.maxY <= contentMaximumY else {
            throw GeometryError.presentationRectOutOfBounds
        }
        return try ImageRect(
            x: (presentationRect.x - horizontalInset) / scale,
            y: (presentationRect.y - verticalInset) / scale,
            width: presentationRect.width / scale,
            height: presentationRect.height / scale
        )
    }
}
