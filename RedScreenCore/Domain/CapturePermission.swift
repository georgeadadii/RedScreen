import Foundation

/// Screen Recording access as RedScreen presents it to the user.
///
/// macOS exposes only "granted" or "not granted" (`CGPreflightScreenCaptureAccess`). RedScreen
/// separates the remaining states itself:
/// - `notDetermined`: RedScreen has never asked, so the next capture may show the system prompt.
/// - `denied`: RedScreen asked once and access is still off. macOS will not prompt again, so the
///   user is sent to System Settings instead of being prompted repeatedly.
/// - `restricted`: access looks allowed but capture is still refused, as happens when a
///   management policy blocks it. The user cannot fix this in System Settings.
public enum ScreenRecordingPermission: Equatable, Sendable {
    case notDetermined
    case denied
    case restricted
    case granted

    /// What the user sees about this state. Contains no window, app, or file information.
    public var guidance: ScreenRecordingGuidance {
        switch self {
        case .notDetermined:
            ScreenRecordingGuidance(
                title: "Screen Recording not set up yet",
                message: "macOS asks once, the first time you start a capture. RedScreen captures only "
                    + "the region, window, or display you choose, and never records continuously.",
                offersSystemSettings: false
            )
        case .denied:
            ScreenRecordingGuidance(
                title: "Screen Recording is off for RedScreen",
                message: "Capturing is blocked until you allow RedScreen in System Settings › Privacy & "
                    + "Security › Screen & System Audio Recording. macOS may ask you to reopen RedScreen "
                    + "afterwards. Importing screenshots still works.",
                offersSystemSettings: true
            )
        case .restricted:
            ScreenRecordingGuidance(
                title: "Screen Recording is restricted on this Mac",
                message: "A policy on this Mac, such as one set by your organization, blocks screen "
                    + "capture. System Settings can't change this; ask your administrator. Importing "
                    + "screenshots still works.",
                offersSystemSettings: false
            )
        case .granted:
            ScreenRecordingGuidance(
                title: "Screen Recording is allowed",
                message: "RedScreen captures only when you start a capture, and only the target you choose.",
                offersSystemSettings: false
            )
        }
    }

    /// The System Settings pane for Screen Recording. Opened only when the user asks.
    public static let systemSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    )!
}

public struct ScreenRecordingGuidance: Equatable, Sendable {
    public let title: String
    public let message: String
    /// Whether opening System Settings can resolve this state.
    public let offersSystemSettings: Bool
}

/// The operating system's Screen Recording check and prompt.
@MainActor
public protocol ScreenRecordingAuthorizing: AnyObject {
    /// Whether access is currently granted. Never shows UI.
    func isGranted() -> Bool
    /// Asks macOS for access. macOS shows its prompt at most once per app; later calls return
    /// immediately. Returns whether access is granted now.
    func requestAccess() -> Bool
}

/// Remembers whether RedScreen has already asked for access, so it never asks twice.
public protocol PermissionRequestRecord: AnyObject {
    var hasRequestedScreenRecording: Bool { get set }
}
