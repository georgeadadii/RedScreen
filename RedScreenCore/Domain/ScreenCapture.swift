import CoreGraphics
import Foundation

/// A display as seen by the capture layer, in Core Graphics global coordinates: points, with the
/// origin at the top-left of the main display and y increasing downward. Other displays may have
/// negative origins. Carries no name, thumbnail, or other identifying content.
public struct CaptureDisplay: Equatable, Sendable {
    public let id: UInt32
    public let frame: CGRect
    /// Backing scale (pixels per point), e.g. 1 or 2. Displays in one setup may differ.
    public let scale: Double

    public init(id: UInt32, frame: CGRect, scale: Double) {
        precondition(scale > 0, "Display scale must be positive")
        self.id = id
        self.frame = frame
        self.scale = scale
    }
}

/// Exactly what the user asked to capture. Windows are identified by number only; titles and
/// application names are shown to the user while choosing but are never stored here.
public enum CaptureTarget: Equatable, Sendable {
    /// A rectangle in Core Graphics global points (top-left origin).
    case region(CGRect)
    case window(id: UInt32)
    case display(id: UInt32)
}

/// Recoverable capture outcomes. Messages never contain window titles, app names, or paths.
public enum CaptureError: Error, Equatable, Sendable {
    /// The user dismissed the selection or capture. Not shown; the prior state is kept.
    case canceled
    /// Screen Recording permission has not been granted.
    case permissionDenied
    /// The chosen window or display closed, moved off screen, or cannot be found.
    case targetUnavailable
    /// The target returned no visible content, as macOS does for protected windows.
    case protectedContent
    /// Displays were added, removed, or rearranged while choosing a target.
    case displayConfigurationChanged
    /// The selected region is smaller than one pixel or lies outside every display.
    case emptyRegion
    /// The capture is larger than the import pixel budget.
    case tooLarge
    case failed

    public var userMessage: String {
        switch self {
        case .canceled:
            "Capture was canceled."
        case .permissionDenied:
            "RedScreen needs Screen Recording permission to capture. Allow it in System Settings › "
                + "Privacy & Security › Screen & System Audio Recording, then try again."
        case .targetUnavailable:
            "That window or display is no longer available. Choose another target and try again."
        case .protectedContent:
            "macOS returned no visible content for that target. It may be protected from capture."
        case .displayConfigurationChanged:
            "Your displays changed while selecting. Try the capture again."
        case .emptyRegion:
            "Drag to select an area on a display, then release to capture it."
        case .tooLarge:
            "The capture is too large to process safely. Capture a smaller area."
        case .failed:
            "The screenshot couldn't be captured. Try again."
        }
    }
}

/// Captures a user-chosen target directly into normalized, in-memory pixels.
///
/// Implementations must capture only `target`, exclude RedScreen's own windows, release capture
/// resources before returning, write no files, log nothing identifying, and throw `CaptureError`
/// for every recoverable outcome (including `.canceled`).
public protocol ScreenCaptureService: Sendable {
    func capture(_ target: CaptureTarget) async throws -> ImportedImage
}

/// Where and at what size a region is captured.
public struct CaptureRegionPlan: Equatable, Sendable {
    public let displayID: UInt32
    /// The region in the display's own points (origin at the display's top-left corner),
    /// aligned to whole device pixels.
    public let sourceRect: CGRect
    public let pixelWidth: Int
    public let pixelHeight: Int
}

/// Pure coordinate conversion for multi-display, mixed-scale setups.
public enum CaptureGeometry {
    /// Converts an AppKit global rect (bottom-left origin on the main display, y up) to Core
    /// Graphics global coordinates (top-left origin, y down). `mainDisplayHeight` is the height
    /// in points of the display whose AppKit origin is (0, 0).
    public static func coreGraphicsRect(fromAppKit rect: CGRect, mainDisplayHeight: Double) -> CGRect {
        CGRect(x: rect.minX, y: mainDisplayHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Plans a region capture on the single display that contains most of `region`.
    ///
    /// A region spanning displays is clipped to that display, because displays may have
    /// different scales and colour spaces and the pipeline holds one raster. The clipped
    /// rectangle is aligned outward to whole device pixels on that display, so nothing the user
    /// selected is cut off and the output is sharp at the display's native scale.
    public static func plan(region: CGRect, displays: [CaptureDisplay]) throws -> CaptureRegionPlan {
        let region = region.standardized
        guard region.width > 0, region.height > 0 else { throw CaptureError.emptyRegion }
        var best: (display: CaptureDisplay, clipped: CGRect, area: Double)?
        for display in displays {
            let clipped = display.frame.intersection(region)
            guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { continue }
            let area = Double(clipped.width * clipped.height)
            if area > (best?.area ?? 0) { best = (display, clipped, area) }
        }
        guard let (display, clipped, _) = best else { throw CaptureError.emptyRegion }

        let scale = display.scale
        let local = clipped.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        let displayPixelWidth = Int((display.frame.width * scale).rounded())
        let displayPixelHeight = Int((display.frame.height * scale).rounded())
        let minX = max(0, Int((local.minX * scale).rounded(.down)))
        let minY = max(0, Int((local.minY * scale).rounded(.down)))
        let maxX = min(displayPixelWidth, Int((local.maxX * scale).rounded(.up)))
        let maxY = min(displayPixelHeight, Int((local.maxY * scale).rounded(.up)))
        guard maxX > minX, maxY > minY else { throw CaptureError.emptyRegion }
        return CaptureRegionPlan(
            displayID: display.id,
            sourceRect: CGRect(x: Double(minX) / scale, y: Double(minY) / scale,
                               width: Double(maxX - minX) / scale, height: Double(maxY - minY) / scale),
            pixelWidth: maxX - minX,
            pixelHeight: maxY - minY
        )
    }

    /// Native pixel size of content `size` points large on a display of `scale`.
    public static func pixelSize(of size: CGSize, scale: Double) -> (width: Int, height: Int) {
        (Int((size.width * scale).rounded(.up)), Int((size.height * scale).rounded(.up)))
    }
}
