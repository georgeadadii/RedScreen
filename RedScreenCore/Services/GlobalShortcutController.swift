import Foundation
import Observation

/// Owns the optional global capture shortcut.
///
/// - Nothing is registered until the user turns the shortcut on. `restore()` at launch only
///   re-registers a shortcut the user enabled earlier.
/// - A combination used by macOS or held by another app is refused with a visible reason; the
///   previous working shortcut stays registered and the saved choice is unchanged.
/// - Turning it off unregisters immediately and is remembered across launches.
@MainActor
@Observable
public final class GlobalShortcutController {
    public enum Status: Equatable, Sendable {
        case off
        case active(GlobalShortcut)
        /// The user turned this shortcut on, but it could not be registered at launch.
        case unavailable(GlobalShortcut, ShortcutRegistrationError)
    }

    public struct Rejection: Equatable, Sendable {
        public let shortcut: GlobalShortcut
        public let error: ShortcutRegistrationError
    }

    public private(set) var status: Status = .off
    /// The most recent change the user tried that was refused. Cleared by a successful change.
    public private(set) var lastRejection: Rejection?

    @ObservationIgnored private let registrar: any GlobalHotKeyRegistering
    @ObservationIgnored private let systemShortcuts: any SystemShortcutCatalog
    @ObservationIgnored private let store: any GlobalShortcutPreferenceStore
    @ObservationIgnored private let onPress: @MainActor () -> Void

    public init(
        registrar: any GlobalHotKeyRegistering,
        systemShortcuts: any SystemShortcutCatalog,
        store: any GlobalShortcutPreferenceStore,
        onPress: @escaping @MainActor () -> Void
    ) {
        self.registrar = registrar
        self.systemShortcuts = systemShortcuts
        self.store = store
        self.onPress = onPress
    }

    public var isEnabled: Bool {
        if case .off = status { return false }
        return true
    }

    /// The shortcut shown in settings: the active or saved one, else the documented default.
    public var displayedShortcut: GlobalShortcut {
        switch status {
        case .active(let shortcut), .unavailable(let shortcut, _): shortcut
        case .off: store.shortcutPreference?.shortcut ?? .documentedDefault
        }
    }

    /// Re-registers the shortcut at launch, only if the user enabled it before.
    public func restore() {
        guard let preference = store.shortcutPreference, preference.isEnabled else {
            status = .off
            return
        }
        do {
            try register(preference.shortcut)
            status = .active(preference.shortcut)
        } catch {
            status = .unavailable(preference.shortcut, error as? ShortcutRegistrationError ?? .failed)
        }
    }

    /// Turns the shortcut on, or changes it. Returns false, and keeps the current state, if the
    /// combination is not allowed or is taken.
    @discardableResult
    public func enable(_ shortcut: GlobalShortcut) -> Bool {
        if status == .active(shortcut) {
            lastRejection = nil
            return true
        }
        do {
            try register(shortcut)
        } catch {
            lastRejection = Rejection(shortcut: shortcut, error: error as? ShortcutRegistrationError ?? .failed)
            return false
        }
        status = .active(shortcut)
        lastRejection = nil
        store.shortcutPreference = GlobalShortcutPreference(isEnabled: true, shortcut: shortcut)
        return true
    }

    /// Turns the shortcut on with the saved choice, or the documented default.
    @discardableResult
    public func enable() -> Bool {
        enable(displayedShortcut)
    }

    /// Turns the shortcut off and remembers that across launches.
    public func disable() {
        let shortcut = displayedShortcut
        registrar.unregister()
        status = .off
        lastRejection = nil
        store.shortcutPreference = GlobalShortcutPreference(isEnabled: false, shortcut: shortcut)
    }

    /// Releases the system-wide registration without changing the saved choice, so a new
    /// instance of RedScreen (after Quit & Reopen) can register the same shortcut.
    public func releaseForRelaunch() {
        registrar.unregister()
        status = .off
    }

    private func register(_ shortcut: GlobalShortcut) throws {
        guard shortcut.isAllowedAsGlobalShortcut else { throw ShortcutRegistrationError.needsModifier }
        guard !systemShortcuts.isReservedBySystem(shortcut) else {
            throw ShortcutRegistrationError.reservedBySystem
        }
        let onPress = onPress
        try registrar.register(shortcut) { onPress() }
    }
}
