import Foundation

/// The only persistent app state outside files the user saves, and the only production use of
/// `UserDefaults` (a security test enforces both). It holds exactly two preferences:
///
/// - `capture.screenRecordingRequested`: whether RedScreen has asked for Screen Recording access,
///   so it never asks twice.
/// - `capture.globalShortcut`: whether the global shortcut is on, and its key code, modifiers,
///   and key label.
///
/// Nothing about screen content, images, text, windows, apps, or files is stored.
public final class CapturePreferenceStore: PermissionRequestRecord, GlobalShortcutPreferenceStore {
    static let requestedKey = "capture.screenRecordingRequested"
    static let shortcutKey = "capture.globalShortcut"
    static let allKeys: Set<String> = [requestedKey, shortcutKey]

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var hasRequestedScreenRecording: Bool {
        get { defaults.bool(forKey: Self.requestedKey) }
        set { defaults.set(newValue, forKey: Self.requestedKey) }
    }

    public var shortcutPreference: GlobalShortcutPreference? {
        get {
            guard let value = defaults.dictionary(forKey: Self.shortcutKey),
                  let enabled = value["enabled"] as? Bool,
                  let keyCode = value["keyCode"] as? Int, let keyCode = UInt16(exactly: keyCode),
                  let modifiers = value["modifiers"] as? Int, let modifiers = UInt8(exactly: modifiers),
                  let label = value["keyLabel"] as? String, (1...8).contains(label.count)
            else { return nil }
            return GlobalShortcutPreference(
                isEnabled: enabled,
                shortcut: GlobalShortcut(keyCode: keyCode, modifiers: .init(rawValue: modifiers), keyLabel: label)
            )
        }
        set {
            guard let newValue else {
                defaults.removeObject(forKey: Self.shortcutKey)
                return
            }
            defaults.set([
                "enabled": newValue.isEnabled,
                "keyCode": Int(newValue.shortcut.keyCode),
                "modifiers": Int(newValue.shortcut.modifiers.rawValue),
                "keyLabel": newValue.shortcut.keyLabel,
            ] as [String: Any], forKey: Self.shortcutKey)
        }
    }
}
