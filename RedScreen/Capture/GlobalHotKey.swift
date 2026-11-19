import AppKit
import Carbon.HIToolbox
import RedScreenCore

/// Registers the capture shortcut with Carbon's `RegisterEventHotKey`.
///
/// This is the lowest-privilege system-wide shortcut mechanism on macOS: it needs neither
/// Accessibility nor Input Monitoring permission, sees only presses of the one registered
/// combination, and never observes other typing. Registration is exclusive, so a combination
/// another app already holds exclusively is refused instead of taken over.
@MainActor
final class CarbonHotKeyRegistrar: GlobalHotKeyRegistering {
    private static let signature: OSType = 0x5244_5343  // "RDSC"

    private var hotKey: EventHotKeyRef?
    private var hotKeyID: UInt32 = 0
    private var nextID: UInt32 = 1
    private var handler: EventHandlerRef?
    private var onPress: (@MainActor () -> Void)?

    func register(_ shortcut: GlobalShortcut, onPress: @escaping @MainActor () -> Void) throws {
        try installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode),
            Self.carbonModifiers(shortcut.modifiers),
            EventHotKeyID(signature: Self.signature, id: id),
            GetEventDispatcherTarget(),
            OptionBits(kEventHotKeyExclusive),
            &reference
        )
        guard status == noErr, let reference else {
            throw status == OSStatus(eventHotKeyExistsErr)
                ? ShortcutRegistrationError.inUseByAnotherApp : ShortcutRegistrationError.failed
        }
        // Replace the previous registration only now that the new one succeeded.
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = reference
        hotKeyID = id
        self.onPress = onPress
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        hotKeyID = 0
        onPress = nil
    }

    fileprivate func handlePress(id: UInt32) {
        guard id == hotKeyID else { return }
        onPress?()
    }

    private func installHandlerIfNeeded() throws {
        guard handler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetEventDispatcherTarget(), carbonHotKeyCallback, 1, &eventType,
            Unmanaged.passUnretained(self).toOpaque(), &handler
        )
        guard status == noErr else { throw ShortcutRegistrationError.failed }
    }

    static func carbonModifiers(_ modifiers: GlobalShortcut.Modifiers) -> UInt32 {
        var flags: UInt32 = 0
        if modifiers.contains(.command) { flags |= UInt32(cmdKey) }
        if modifiers.contains(.shift) { flags |= UInt32(shiftKey) }
        if modifiers.contains(.option) { flags |= UInt32(optionKey) }
        if modifiers.contains(.control) { flags |= UInt32(controlKey) }
        return flags
    }
}

/// Carbon delivers hot key events on the main thread's event dispatcher.
private func carbonHotKeyCallback(
    _: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var id = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        nil, MemoryLayout<EventHotKeyID>.size, nil, &id
    )
    guard status == noErr else { return status }
    let registrar = Unmanaged<CarbonHotKeyRegistrar>.fromOpaque(userData).takeUnretainedValue()
    let pressedID = id.id
    MainActor.assumeIsolated { registrar.handlePress(id: pressedID) }
    return noErr
}

/// The enabled shortcuts in System Settings › Keyboard › Keyboard Shortcuts, plus the built-in
/// screenshot shortcuts, which are always treated as reserved.
@MainActor
final class SymbolicHotKeyCatalog: SystemShortcutCatalog {
    private static let modifierMask = UInt32(cmdKey | shiftKey | optionKey | controlKey)

    /// ⇧⌘3, ⇧⌘4, ⇧⌘5, ⌃⇧⌘3, and ⌃⇧⌘4.
    private static let screenshotShortcuts: Set<[UInt32]> = [
        [20, UInt32(cmdKey | shiftKey)], [21, UInt32(cmdKey | shiftKey)], [23, UInt32(cmdKey | shiftKey)],
        [20, UInt32(cmdKey | shiftKey | controlKey)], [21, UInt32(cmdKey | shiftKey | controlKey)],
    ]

    func isReservedBySystem(_ shortcut: GlobalShortcut) -> Bool {
        let code = UInt32(shortcut.keyCode)
        let modifiers = CarbonHotKeyRegistrar.carbonModifiers(shortcut.modifiers)
        if Self.screenshotShortcuts.contains([code, modifiers]) { return true }

        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr,
              let entries = unmanaged?.takeRetainedValue() as? [[String: Any]] else { return false }
        return entries.contains { entry in
            guard (entry[kHISymbolicHotKeyEnabled as String] as? Bool) == true,
                  let entryCode = (entry[kHISymbolicHotKeyCode as String] as? NSNumber)?.uint32Value,
                  let entryModifiers = (entry[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.uint32Value
            else { return false }
            return entryCode == code && entryModifiers & Self.modifierMask == modifiers
        }
    }
}

extension GlobalShortcut {
    /// Builds a shortcut from a key press recorded in the app's own window.
    @MainActor
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: Modifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        guard let label = Self.label(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers) else {
            return nil
        }
        self.init(keyCode: event.keyCode, modifiers: modifiers, keyLabel: label)
    }

    private static let namedKeys: [UInt16: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 49: "Space", 36: "↩", 48: "⇥", 51: "⌫",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    private static func label(keyCode: UInt16, characters: String?) -> String? {
        if let named = namedKeys[keyCode] { return named }
        guard let characters, let scalar = characters.unicodeScalars.first,
              !CharacterSet.controlCharacters.contains(scalar),
              !(0xF700...0xF8FF).contains(scalar.value) else { return nil }
        return characters.uppercased()
    }
}
