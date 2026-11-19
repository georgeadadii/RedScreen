import Foundation

/// A system-wide key combination that starts a capture.
///
/// `keyCode` is a macOS virtual key code (layout independent). `keyLabel` is what the key showed
/// when the user recorded it, kept only for display.
public struct GlobalShortcut: Hashable, Sendable {
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
    }

    public let keyCode: UInt16
    public let modifiers: Modifiers
    public let keyLabel: String

    public init(keyCode: UInt16, modifiers: Modifiers, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    /// The documented default, ⌥⇧⌘R. It is offered to the user but never registered until they
    /// turn the shortcut on.
    public static let documentedDefault = GlobalShortcut(
        keyCode: 15, modifiers: [.option, .shift, .command], keyLabel: "R"
    )

    /// Symbols in the standard macOS order, for example "⌃⌥⇧⌘R".
    public var displayString: String {
        var symbols = ""
        if modifiers.contains(.control) { symbols += "⌃" }
        if modifiers.contains(.option) { symbols += "⌥" }
        if modifiers.contains(.shift) { symbols += "⇧" }
        if modifiers.contains(.command) { symbols += "⌘" }
        return symbols + keyLabel
    }

    /// Spoken form for VoiceOver, for example "Option Shift Command R".
    public var accessibilityDescription: String {
        var words: [String] = []
        if modifiers.contains(.control) { words.append("Control") }
        if modifiers.contains(.option) { words.append("Option") }
        if modifiers.contains(.shift) { words.append("Shift") }
        if modifiers.contains(.command) { words.append("Command") }
        return (words + [keyLabel]).joined(separator: " ")
    }

    /// A global shortcut needs Command, Control, or Option, so ordinary typing (including
    /// Shift-only capitals) is never captured system-wide.
    public var isAllowedAsGlobalShortcut: Bool {
        !modifiers.isDisjoint(with: [.command, .control, .option]) && !keyLabel.isEmpty
    }
}

/// Why a shortcut could not be turned on. RedScreen never takes a combination from another
/// app or from macOS; it reports one of these and keeps the previous setting.
public enum ShortcutRegistrationError: Error, Equatable, Sendable {
    /// The combination lacks Command, Control, or Option.
    case needsModifier
    /// An enabled macOS keyboard shortcut already uses it.
    case reservedBySystem
    /// Another app holds it exclusively.
    case inUseByAnotherApp
    case failed

    public var userMessage: String {
        switch self {
        case .needsModifier:
            "Include Command, Control, or Option in the shortcut."
        case .reservedBySystem:
            "macOS already uses this shortcut. Choose another, or turn that one off in System "
                + "Settings › Keyboard › Keyboard Shortcuts."
        case .inUseByAnotherApp:
            "Another app is using this shortcut. Choose a different one."
        case .failed:
            "The shortcut couldn't be turned on. Choose a different one."
        }
    }
}

/// Registers one system-wide hot key without Accessibility or Input Monitoring permission.
@MainActor
public protocol GlobalHotKeyRegistering: AnyObject {
    /// Registers `shortcut`, replacing the current registration only if this one succeeds.
    /// Must fail rather than take a combination another app holds.
    func register(_ shortcut: GlobalShortcut, onPress: @escaping @MainActor () -> Void) throws
    /// Removes the current registration, if any.
    func unregister()
}

/// Enabled macOS keyboard shortcuts, such as the built-in screenshot shortcuts.
@MainActor
public protocol SystemShortcutCatalog: AnyObject {
    func isReservedBySystem(_ shortcut: GlobalShortcut) -> Bool
}

/// The user's saved shortcut choice. `nil` means the user has never turned it on.
public struct GlobalShortcutPreference: Equatable, Sendable {
    public var isEnabled: Bool
    public var shortcut: GlobalShortcut

    public init(isEnabled: Bool, shortcut: GlobalShortcut) {
        self.isEnabled = isEnabled
        self.shortcut = shortcut
    }
}

public protocol GlobalShortcutPreferenceStore: AnyObject {
    var shortcutPreference: GlobalShortcutPreference? { get set }
}
