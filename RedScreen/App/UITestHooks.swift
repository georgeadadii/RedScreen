#if DEBUG
import AppKit
import CoreGraphics
import RedScreenCore

/// Fakes the UI tests inject through launch arguments. Compiled into Debug builds only, so a
/// release build can never be told to skip the real permission check or shortcut registration.
///
/// - `-RedScreenUITestPermission notDetermined|denied|restricted|granted`
/// - `-RedScreenUITestFakeCapture YES`: captures return a synthetic grey image.
/// - `-RedScreenUITestFakeShortcuts YES`: in-memory preferences, a fake registrar, and a fake
///   system catalog. ⌃⌥⌘K acts as held by another app and ⌃⌥⌘J as reserved by macOS, so the
///   tests never type a real system shortcut.
enum UITestHooks {
    private static let arguments = ProcessInfo.processInfo.arguments

    private static func value(_ name: String) -> String? {
        guard let index = arguments.firstIndex(of: "-\(name)"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    static var permission: ScreenRecordingPermission? {
        switch value("RedScreenUITestPermission") {
        case "notDetermined": .notDetermined
        case "denied": .denied
        case "restricted": .restricted
        case "granted": .granted
        default: nil
        }
    }

    static var usesFakeCapture: Bool { value("RedScreenUITestFakeCapture") == "YES" }
    static var usesFakeShortcuts: Bool { value("RedScreenUITestFakeShortcuts") == "YES" }
}

/// Reports a fixed state and never shows a prompt.
@MainActor
final class FakeScreenRecordingAuthorizer: ScreenRecordingAuthorizing {
    private let granted: Bool

    init(_ permission: ScreenRecordingPermission) {
        granted = permission == .granted || permission == .restricted
    }

    func isGranted() -> Bool { granted }
    func requestAccess() -> Bool { granted }
}

final class InMemoryCapturePreferences: PermissionRequestRecord, GlobalShortcutPreferenceStore {
    var hasRequestedScreenRecording: Bool
    var shortcutPreference: GlobalShortcutPreference?

    init(hasRequested: Bool) { hasRequestedScreenRecording = hasRequested }
}

@MainActor
final class FakeHotKeyRegistrar: GlobalHotKeyRegistering {
    static let heldByAnotherApp = GlobalShortcut(keyCode: 40, modifiers: [.control, .option, .command], keyLabel: "K")

    func register(_ shortcut: GlobalShortcut, onPress: @escaping @MainActor () -> Void) throws {
        if shortcut.keyCode == Self.heldByAnotherApp.keyCode, shortcut.modifiers == Self.heldByAnotherApp.modifiers {
            throw ShortcutRegistrationError.inUseByAnotherApp
        }
    }

    func unregister() {}
}

@MainActor
final class FakeSystemShortcutCatalog: SystemShortcutCatalog {
    static let reserved = GlobalShortcut(keyCode: 38, modifiers: [.control, .option, .command], keyLabel: "J")

    func isReservedBySystem(_ shortcut: GlobalShortcut) -> Bool {
        shortcut.keyCode == Self.reserved.keyCode && shortcut.modifiers == Self.reserved.modifiers
    }
}

/// Synthetic capture: a flat grey frame, no screen content.
struct FakeScreenCaptureService: ScreenCaptureService {
    func capture(_ target: CaptureTarget) async throws -> ImportedImage {
        guard let context = CGContext(
            data: nil, width: 320, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw CaptureError.failed }
        context.setFillColor(gray: 0.6, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 320, height: 200))
        guard let image = context.makeImage() else { throw CaptureError.failed }
        return try CapturedImageNormalizer.normalize(image, treatsTransparentAsProtected: false)
    }
}
#endif
