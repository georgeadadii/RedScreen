import Foundation
import Observation

/// Tracks Screen Recording access and decides, for each user-started capture, whether it may
/// proceed, whether macOS may prompt, or whether the user needs guidance instead.
///
/// - The system prompt is requested only from `authorizeCapture()`, which the app calls only in
///   direct response to a capture command or the user's capture shortcut, and only once ever.
/// - `refresh()` re-reads the system state without prompting, for example when the app becomes
///   active after the user changed System Settings.
@MainActor
@Observable
public final class CapturePermissionModel {
    public private(set) var state: ScreenRecordingPermission
    /// Called when access becomes granted after not being granted, for example after the user
    /// allows RedScreen in System Settings and returns or chooses Check Again.
    @ObservationIgnored public var onGranted: (@MainActor () -> Void)?

    @ObservationIgnored private let authorizer: any ScreenRecordingAuthorizing
    @ObservationIgnored private let record: any PermissionRequestRecord
    @ObservationIgnored private var isRestricted = false

    public init(authorizer: any ScreenRecordingAuthorizing, record: any PermissionRequestRecord) {
        self.authorizer = authorizer
        self.record = record
        state = .notDetermined
        refresh()
    }

    /// Re-reads the current state. Never prompts.
    public func refresh() {
        let granted = authorizer.isGranted()
        if granted { record.hasRequestedScreenRecording = true }
        let previous = state
        state = Self.state(granted: granted, requested: record.hasRequestedScreenRecording,
                           restricted: isRestricted)
        if state == .granted, previous != .granted { onGranted?() }
    }

    /// Called when the user starts a capture. Returns true if the capture may proceed.
    ///
    /// Only the `notDetermined` state asks macOS, and it is recorded first, so a denied or
    /// restricted user is never prompted again; they get guidance instead.
    public func authorizeCapture() -> Bool {
        refresh()
        switch state {
        case .granted:
            return true
        case .notDetermined:
            record.hasRequestedScreenRecording = true
            let granted = authorizer.requestAccess()
            refresh()
            return granted && state == .granted
        case .denied, .restricted:
            return false
        }
    }

    /// Records that capture was refused even though access looks granted, as a management
    /// policy does. Cleared by `checkAgain()`.
    public func noteRestricted() {
        isRestricted = true
        refresh()
    }

    /// The user's "Check Again": forgets a restriction observed earlier and re-reads the state.
    public func checkAgain() {
        isRestricted = false
        refresh()
    }

    /// The capture failure to report when `authorizeCapture()` returns false.
    public var blockedCaptureError: CaptureError {
        state == .restricted ? .permissionRestricted : .permissionDenied
    }

    static func state(granted: Bool, requested: Bool, restricted: Bool) -> ScreenRecordingPermission {
        if restricted { return .restricted }
        if granted { return .granted }
        return requested ? .denied : .notDetermined
    }
}
