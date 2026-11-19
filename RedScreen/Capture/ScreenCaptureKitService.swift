import AppKit
import CoreGraphics
import RedScreenCore
@preconcurrency import ScreenCaptureKit

/// Captures one user-chosen region, window, or display with ScreenCaptureKit's single-frame
/// screenshot API. ScreenCaptureKit and permission types stay in the app target.
///
/// - Access is only checked here, never requested; `CapturePermissionModel` asks macOS once,
///   when the user starts a capture.
/// - RedScreen's own windows (document, popover, selection overlay) are always excluded.
/// - `SCScreenshotManager` produces one frame and holds no stream open afterwards.
/// - The frame is normalized in memory; nothing is written to disk and nothing identifying
///   (titles, application names, thumbnails) is logged or retained.
struct ScreenCaptureKitService: ScreenCaptureService {
    func capture(_ target: CaptureTarget) async throws -> ImportedImage {
        try Task.checkCancellation()
        try await Self.requireScreenRecordingAccess()
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw Self.map(error)
        }
        let ownApplications = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }

        let filter: SCContentFilter
        let configuration = SCStreamConfiguration()
        configuration.showsCursor = false
        configuration.captureResolution = .best
        let treatsTransparentAsProtected: Bool

        switch target {
        case .display(let id):
            guard let display = content.displays.first(where: { $0.displayID == id }) else {
                throw CaptureError.targetUnavailable
            }
            filter = SCContentFilter(display: display, excludingApplications: ownApplications, exceptingWindows: [])
            let size = CaptureGeometry.pixelSize(of: filter.contentRect.size, scale: Double(filter.pointPixelScale))
            configuration.width = size.width
            configuration.height = size.height
            configuration.colorSpaceName = Self.colorSpaceName(forDisplay: id)
            treatsTransparentAsProtected = false

        case .region(let rect):
            let displays = await MainActor.run { Self.currentDisplays() }
            let plan = try CaptureGeometry.plan(region: rect, displays: displays)
            guard let display = content.displays.first(where: { $0.displayID == plan.displayID }) else {
                throw CaptureError.displayConfigurationChanged
            }
            filter = SCContentFilter(display: display, excludingApplications: ownApplications, exceptingWindows: [])
            configuration.sourceRect = plan.sourceRect
            configuration.width = plan.pixelWidth
            configuration.height = plan.pixelHeight
            configuration.colorSpaceName = Self.colorSpaceName(forDisplay: plan.displayID)
            treatsTransparentAsProtected = false

        case .window(let id):
            guard let window = content.windows.first(where: { $0.windowID == id }),
                  window.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier else {
                throw CaptureError.targetUnavailable
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            let size = CaptureGeometry.pixelSize(of: filter.contentRect.size, scale: Double(filter.pointPixelScale))
            configuration.width = size.width
            configuration.height = size.height
            configuration.ignoreShadowsSingleWindow = true
            configuration.colorSpaceName = Self.colorSpaceName(forDisplay: Self.displayID(containing: window.frame))
            treatsTransparentAsProtected = true
        }

        try Task.checkCancellation()
        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            throw Self.map(error)
        }
        try Task.checkCancellation()
        return try CapturedImageNormalizer.normalize(image, treatsTransparentAsProtected: treatsTransparentAsProtected)
    }

    // MARK: - Displays and windows offered to the user

    /// Displays in Core Graphics global points with their backing scales.
    @MainActor
    static func currentDisplays() -> [CaptureDisplay] {
        NSScreen.screens.compactMap { screen in
            guard let id = screen.displayID else { return nil }
            return CaptureDisplay(id: id, frame: CGDisplayBounds(id), scale: Double(screen.backingScaleFactor))
        }
    }

    /// On-screen, normal-layer windows of other applications, for the user to choose from.
    /// The labels exist only in the menu shown to the user.
    static func windowChoices() async throws -> [(id: UInt32, label: String)] {
        try await requireScreenRecordingAccess()
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        } catch {
            throw map(error)
        }
        return content.windows
            .filter { $0.windowLayer == 0 && $0.frame.width >= 40 && $0.frame.height >= 40
                && $0.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier }
            .map { window in
                let app = window.owningApplication?.applicationName ?? "Window"
                let title = window.title.flatMap { $0.isEmpty ? nil : $0 }
                return (window.windowID, title.map { "\(app) — \($0)" } ?? app)
            }
    }

    // MARK: - Permission and errors

    /// Checks access without prompting. The prompt is requested only by
    /// `CapturePermissionModel.authorizeCapture()` when the user starts a capture.
    private static func requireScreenRecordingAccess() async throws {
        guard CGPreflightScreenCaptureAccess() else { throw CaptureError.permissionDenied }
    }

    private static func map(_ error: any Error) -> CaptureError {
        if error is CancellationError { return .canceled }
        if let capture = error as? CaptureError { return capture }
        if let stream = error as? SCStreamError {
            switch stream.code {
            // Refused although access is granted: a policy is blocking capture.
            case .userDeclined: return CGPreflightScreenCaptureAccess() ? .permissionRestricted : .permissionDenied
            case .missingEntitlements: return .permissionDenied
            case .userStopped: return .canceled
            case .noCaptureSource, .noDisplayList, .noWindowList: return .targetUnavailable
            default: return .failed
            }
        }
        return .failed
    }

    // MARK: - Colour

    /// Captures wide-gamut displays in Display P3 and everything else in sRGB, matching the
    /// rendering colour spaces the pipeline supports.
    private static func colorSpaceName(forDisplay id: UInt32?) -> CFString {
        guard let id, let space = CGDisplayCopyColorSpace(id) as CGColorSpace?, space.isWideGamutRGB else {
            return CGColorSpace.sRGB
        }
        return CGColorSpace.displayP3
    }

    private static func displayID(containing frame: CGRect) -> UInt32? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        let center = CGPoint(x: frame.midX, y: frame.midY)
        guard CGGetDisplaysWithPoint(center, UInt32(ids.count), &ids, &count) == .success, count > 0 else {
            return nil
        }
        return ids[0]
    }
}

/// macOS's Screen Recording check (never prompts) and request (prompts at most once per app).
@MainActor
final class SystemScreenRecordingAuthorizer: ScreenRecordingAuthorizing {
    func isGranted() -> Bool { CGPreflightScreenCaptureAccess() }
    func requestAccess() -> Bool { CGRequestScreenCaptureAccess() }
}

extension NSScreen {
    var displayID: UInt32? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
