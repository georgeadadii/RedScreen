import Foundation
@testable import RedScreenCore
import XCTest

@MainActor
private final class FakeAuthorizer: ScreenRecordingAuthorizing {
    var granted = false
    /// What the user answers in the system prompt, if one is shown.
    var grantsWhenPrompted = false
    private(set) var promptCount = 0

    func isGranted() -> Bool { granted }

    func requestAccess() -> Bool {
        promptCount += 1
        if grantsWhenPrompted { granted = true }
        return granted
    }
}

private final class FakeRecord: PermissionRequestRecord, GlobalShortcutPreferenceStore {
    var hasRequestedScreenRecording = false
    var shortcutPreference: GlobalShortcutPreference?
}

@MainActor
private final class FakeRegistrar: GlobalHotKeyRegistering {
    var takenByOtherApps: Set<GlobalShortcut> = []
    private(set) var registered: GlobalShortcut?
    private(set) var registerCalls = 0
    private var onPress: (@MainActor () -> Void)?

    func register(_ shortcut: GlobalShortcut, onPress: @escaping @MainActor () -> Void) throws {
        registerCalls += 1
        if takenByOtherApps.contains(shortcut) { throw ShortcutRegistrationError.inUseByAnotherApp }
        registered = shortcut
        self.onPress = onPress
    }

    func unregister() {
        registered = nil
        onPress = nil
    }

    func press() { onPress?() }
}

@MainActor
private final class FakeSystemShortcuts: SystemShortcutCatalog {
    var reserved: Set<GlobalShortcut> = []
    func isReservedBySystem(_ shortcut: GlobalShortcut) -> Bool { reserved.contains(shortcut) }
}

@MainActor
final class CapturePermissionModelTests: XCTestCase {
    private var authorizer: FakeAuthorizer!
    private var record: FakeRecord!

    override func setUp() async throws {
        authorizer = FakeAuthorizer()
        record = FakeRecord()
    }

    func testInitialStatesWithoutPrompting() {
        XCTAssertEqual(CapturePermissionModel(authorizer: authorizer, record: record).state, .notDetermined)

        record.hasRequestedScreenRecording = true
        XCTAssertEqual(CapturePermissionModel(authorizer: authorizer, record: record).state, .denied)

        authorizer.granted = true
        XCTAssertEqual(CapturePermissionModel(authorizer: authorizer, record: record).state, .granted)
        XCTAssertEqual(authorizer.promptCount, 0, "Reading the state must never prompt")
    }

    func testGrantedProceedsWithoutPrompt() {
        authorizer.granted = true
        let model = CapturePermissionModel(authorizer: authorizer, record: record)
        XCTAssertTrue(model.authorizeCapture())
        XCTAssertEqual(authorizer.promptCount, 0)
    }

    func testNotDeterminedPromptsOnceThenGuidesInsteadOfPromptingAgain() {
        let model = CapturePermissionModel(authorizer: authorizer, record: record)
        XCTAssertFalse(model.authorizeCapture())
        XCTAssertEqual(authorizer.promptCount, 1)
        XCTAssertEqual(model.state, .denied)
        XCTAssertEqual(model.blockedCaptureError, .permissionDenied)
        XCTAssertTrue(record.hasRequestedScreenRecording)

        XCTAssertFalse(model.authorizeCapture())
        XCTAssertFalse(model.authorizeCapture())
        XCTAssertEqual(authorizer.promptCount, 1, "A denied user is guided, not prompted again")

        // Relaunch: the record survives, so the new model does not prompt either.
        let relaunched = CapturePermissionModel(authorizer: authorizer, record: record)
        XCTAssertFalse(relaunched.authorizeCapture())
        XCTAssertEqual(authorizer.promptCount, 1)
    }

    func testNotDeterminedGrantedFromThePrompt() {
        authorizer.grantsWhenPrompted = true
        let model = CapturePermissionModel(authorizer: authorizer, record: record)
        XCTAssertTrue(model.authorizeCapture())
        XCTAssertEqual(model.state, .granted)
        XCTAssertEqual(authorizer.promptCount, 1)
    }

    func testDeniedRecoversAfterSystemSettingsChange() {
        record.hasRequestedScreenRecording = true
        let model = CapturePermissionModel(authorizer: authorizer, record: record)
        XCTAssertEqual(model.state, .denied)

        authorizer.granted = true  // The user allowed RedScreen in System Settings.
        model.refresh()
        XCTAssertEqual(model.state, .granted)
        XCTAssertTrue(model.authorizeCapture())

        authorizer.granted = false  // ...and later turned it off again.
        model.refresh()
        XCTAssertEqual(model.state, .denied)
        XCTAssertEqual(authorizer.promptCount, 0)
    }

    /// After a reset or removal from System Settings, the user can ask again: once per click,
    /// never automatically, and only when it can help.
    func testAskAgainRequestsOncePerClickOnlyWhenDenied() {
        record.hasRequestedScreenRecording = true  // Asked before, then removed from the list.
        let model = CapturePermissionModel(authorizer: authorizer, record: record)
        XCTAssertEqual(model.state, .denied)
        XCTAssertFalse(model.authorizeCapture())
        XCTAssertEqual(authorizer.promptCount, 0, "Starting a capture still never re-prompts")

        XCTAssertFalse(model.requestAgain())
        XCTAssertEqual(authorizer.promptCount, 1)
        XCTAssertEqual(model.state, .denied)

        authorizer.grantsWhenPrompted = true
        var grants = 0
        model.onGranted = { grants += 1 }
        XCTAssertTrue(model.requestAgain())
        XCTAssertEqual(model.state, .granted)
        XCTAssertEqual(grants, 1, "The banner clears when asking again succeeds")
        XCTAssertTrue(model.requestAgain(), "Already granted: nothing to ask")
        XCTAssertEqual(authorizer.promptCount, 2)

        model.noteRestricted()
        XCTAssertFalse(model.requestAgain(), "A policy restriction is not fixed by asking")
        XCTAssertEqual(authorizer.promptCount, 2)
    }

    func testAskAgainIsNotOfferedBeforeTheFirstRequest() {
        let model = CapturePermissionModel(authorizer: authorizer, record: record)
        XCTAssertEqual(model.state, .notDetermined)
        XCTAssertFalse(model.requestAgain())
        XCTAssertEqual(authorizer.promptCount, 0, "The first request belongs to a capture")
    }

    func testBecomingGrantedIsReportedOnceAndOnlyOnTheTransition() {
        record.hasRequestedScreenRecording = true
        let model = CapturePermissionModel(authorizer: authorizer, record: record)
        var grants = 0
        model.onGranted = { grants += 1 }
        model.refresh()
        XCTAssertEqual(grants, 0, "Still denied")

        authorizer.granted = true  // Allowed in System Settings.
        model.checkAgain()
        XCTAssertEqual(grants, 1)
        model.refresh()
        model.checkAgain()
        XCTAssertEqual(grants, 1, "Not repeated while it stays granted")

        model.noteRestricted()
        model.checkAgain()
        XCTAssertEqual(grants, 2, "Restricted back to granted is a new transition")
    }

    func testGrantedOutsideRedScreenIsRemembered() {
        authorizer.granted = true
        let model = CapturePermissionModel(authorizer: authorizer, record: record)
        authorizer.granted = false
        model.refresh()
        XCTAssertEqual(model.state, .denied, "Access seen once means macOS will not prompt again")
    }

    func testRestrictedBlocksWithoutPromptUntilCheckedAgain() {
        authorizer.granted = true
        let model = CapturePermissionModel(authorizer: authorizer, record: record)
        model.noteRestricted()
        XCTAssertEqual(model.state, .restricted)
        XCTAssertFalse(model.authorizeCapture())
        XCTAssertEqual(model.blockedCaptureError, .permissionRestricted)
        model.refresh()
        XCTAssertEqual(model.state, .restricted, "A refresh alone does not clear a policy block")

        model.checkAgain()
        XCTAssertEqual(model.state, .granted)
        XCTAssertEqual(authorizer.promptCount, 0)
    }

    func testGuidanceForEveryState() {
        let states: [ScreenRecordingPermission] = [.notDetermined, .denied, .restricted, .granted]
        for state in states {
            let guidance = state.guidance
            XCTAssertFalse(guidance.title.isEmpty)
            XCTAssertFalse(guidance.message.isEmpty)
            XCTAssertFalse(guidance.message.contains("/"))
        }
        XCTAssertTrue(ScreenRecordingPermission.denied.guidance.offersSystemSettings)
        XCTAssertTrue(ScreenRecordingPermission.denied.guidance.offersRequestAgain)
        XCTAssertTrue(ScreenRecordingPermission.denied.guidance.message.contains("Ask macOS Again"))
        for state in [ScreenRecordingPermission.notDetermined, .restricted, .granted] {
            XCTAssertFalse(state.guidance.offersRequestAgain, "\(state)")
        }
        XCTAssertTrue(ScreenRecordingPermission.denied.guidance.message.contains("Screen & System Audio Recording"))
        XCTAssertFalse(ScreenRecordingPermission.restricted.guidance.offersSystemSettings,
                       "System Settings cannot lift a policy restriction")
        XCTAssertTrue(ScreenRecordingPermission.restricted.guidance.message.contains("administrator"))
        XCTAssertFalse(ScreenRecordingPermission.notDetermined.guidance.offersSystemSettings)
        XCTAssertFalse(ScreenRecordingPermission.granted.guidance.offersSystemSettings)
        XCTAssertEqual(ScreenRecordingPermission.systemSettingsURL.scheme, "x-apple.systempreferences")
        XCTAssertTrue(ScreenRecordingPermission.systemSettingsURL.absoluteString.hasSuffix("Privacy_ScreenCapture"))
    }
}

@MainActor
final class GlobalShortcutControllerTests: XCTestCase {
    private var registrar: FakeRegistrar!
    private var system: FakeSystemShortcuts!
    private var store: FakeRecord!
    private var presses = 0

    private let other = GlobalShortcut(keyCode: 0, modifiers: [.control, .command], keyLabel: "A")

    override func setUp() async throws {
        registrar = FakeRegistrar()
        system = FakeSystemShortcuts()
        store = FakeRecord()
        presses = 0
    }

    private func makeController() -> GlobalShortcutController {
        GlobalShortcutController(registrar: registrar, systemShortcuts: system, store: store) { [weak self] in
            self?.presses += 1
        }
    }

    func testNothingRegisteredUntilTheUserEnablesIt() {
        let controller = makeController()
        controller.restore()
        XCTAssertEqual(controller.status, .off)
        XCTAssertEqual(registrar.registerCalls, 0)
        XCTAssertEqual(controller.displayedShortcut, .documentedDefault)
        XCTAssertNil(store.shortcutPreference)
    }

    func testEnableDefaultRegistersPersistsAndFires() {
        let controller = makeController()
        XCTAssertTrue(controller.enable())
        XCTAssertEqual(controller.status, .active(.documentedDefault))
        XCTAssertEqual(registrar.registered, .documentedDefault)
        XCTAssertEqual(store.shortcutPreference, GlobalShortcutPreference(isEnabled: true, shortcut: .documentedDefault))
        registrar.press()
        XCTAssertEqual(presses, 1)
    }

    func testChangeReplacesRegistration() {
        let controller = makeController()
        controller.enable()
        XCTAssertTrue(controller.enable(other))
        XCTAssertEqual(controller.status, .active(other))
        XCTAssertEqual(registrar.registered, other)
        XCTAssertEqual(store.shortcutPreference?.shortcut, other)
    }

    func testConflictWithAnotherAppKeepsPreviousShortcut() {
        registrar.takenByOtherApps = [other]
        let controller = makeController()
        controller.enable()
        XCTAssertFalse(controller.enable(other))
        XCTAssertEqual(controller.status, .active(.documentedDefault), "The working shortcut stays")
        XCTAssertEqual(registrar.registered, .documentedDefault)
        XCTAssertEqual(controller.lastRejection, .init(shortcut: other, error: .inUseByAnotherApp))
        XCTAssertEqual(store.shortcutPreference?.shortcut, .documentedDefault, "A refused choice is not saved")

        XCTAssertTrue(controller.enable(.documentedDefault))
        XCTAssertNil(controller.lastRejection)
    }

    func testSystemShortcutIsNeverTaken() {
        system.reserved = [other]
        let controller = makeController()
        XCTAssertFalse(controller.enable(other))
        XCTAssertEqual(controller.status, .off)
        XCTAssertEqual(registrar.registerCalls, 0, "A macOS shortcut is refused before registering")
        XCTAssertEqual(controller.lastRejection?.error, .reservedBySystem)
        XCTAssertNil(store.shortcutPreference)
    }

    func testShortcutWithoutCommandControlOrOptionIsRefused() {
        let controller = makeController()
        let shiftOnly = GlobalShortcut(keyCode: 15, modifiers: [.shift], keyLabel: "R")
        let bare = GlobalShortcut(keyCode: 15, modifiers: [], keyLabel: "R")
        XCTAssertFalse(controller.enable(shiftOnly))
        XCTAssertFalse(controller.enable(bare))
        XCTAssertEqual(controller.lastRejection?.error, .needsModifier)
        XCTAssertEqual(registrar.registerCalls, 0)
    }

    func testDisableUnregistersAndIsRememberedAcrossRelaunch() {
        let controller = makeController()
        controller.enable(other)
        controller.disable()
        XCTAssertEqual(controller.status, .off)
        XCTAssertNil(registrar.registered)
        XCTAssertEqual(store.shortcutPreference, GlobalShortcutPreference(isEnabled: false, shortcut: other))
        XCTAssertEqual(controller.displayedShortcut, other, "The choice is kept for turning it back on")

        let relaunched = makeController()
        relaunched.restore()
        XCTAssertEqual(relaunched.status, .off)
        XCTAssertNil(registrar.registered)

        XCTAssertTrue(relaunched.enable())
        XCTAssertEqual(relaunched.status, .active(other))
    }

    /// Quit & Reopen: the old instance releases the hot key without changing the saved choice,
    /// so the new instance registers the same shortcut.
    func testReleaseForRelaunchHandsTheShortcutToTheNextInstance() {
        let old = makeController()
        old.enable(other)
        old.releaseForRelaunch()
        XCTAssertNil(registrar.registered)
        XCTAssertEqual(old.status, .off)
        XCTAssertEqual(store.shortcutPreference, GlobalShortcutPreference(isEnabled: true, shortcut: other))

        let next = makeController()
        next.restore()
        XCTAssertEqual(next.status, .active(other))
    }

    func testRelaunchRestoresAnEnabledShortcut() {
        makeController().enable(other)
        registrar.unregister()  // The process ended.

        let relaunched = makeController()
        relaunched.restore()
        XCTAssertEqual(relaunched.status, .active(other))
        XCTAssertEqual(registrar.registered, other)
    }

    func testRelaunchReportsAShortcutTakenSinceWithoutOverriding() {
        makeController().enable(other)
        registrar.unregister()
        registrar.takenByOtherApps = [other]

        let relaunched = makeController()
        relaunched.restore()
        XCTAssertEqual(relaunched.status, .unavailable(other, .inUseByAnotherApp))
        XCTAssertTrue(relaunched.isEnabled)
        XCTAssertNil(registrar.registered)
        XCTAssertEqual(store.shortcutPreference?.isEnabled, true, "The user's choice is kept")
    }

    func testShortcutFormatting() {
        let all = GlobalShortcut(keyCode: 1, modifiers: [.command, .shift, .option, .control], keyLabel: "S")
        XCTAssertEqual(all.displayString, "⌃⌥⇧⌘S")
        XCTAssertEqual(all.accessibilityDescription, "Control Option Shift Command S")
        XCTAssertEqual(GlobalShortcut.documentedDefault.displayString, "⌥⇧⌘R")
    }

    func testPreferenceStorePersistsAcrossInstances() throws {
        let suite = "RedScreenCoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = CapturePreferenceStore(defaults: defaults)
        XCTAssertFalse(first.hasRequestedScreenRecording)
        XCTAssertNil(first.shortcutPreference)
        first.hasRequestedScreenRecording = true
        first.shortcutPreference = GlobalShortcutPreference(isEnabled: true, shortcut: other)

        let second = CapturePreferenceStore(defaults: defaults)
        XCTAssertTrue(second.hasRequestedScreenRecording)
        XCTAssertEqual(second.shortcutPreference, GlobalShortcutPreference(isEnabled: true, shortcut: other))

        second.shortcutPreference = nil
        XCTAssertNil(defaults.object(forKey: CapturePreferenceStore.shortcutKey))
    }

    /// Only the two documented keys, holding primitive values, are ever written.
    func testCapturePreferencesAreTheOnlyPersistedState() throws {
        let suite = "RedScreenCoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CapturePreferenceStore(defaults: defaults)
        store.hasRequestedScreenRecording = true
        store.shortcutPreference = GlobalShortcutPreference(isEnabled: false, shortcut: .documentedDefault)
        store.acceptsEditorHints = true
        store.savedProfileDocuments = [String(decoding: try DetectionProfileCodec.encode(
            DetectionProfile(name: "Stored", likelyThreshold: 70, reviewThreshold: 35)), as: UTF8.self)]
        store.selectedProfileName = "Stored"

        let written = try XCTUnwrap(defaults.persistentDomain(forName: suite))
        XCTAssertEqual(Set(written.keys), CapturePreferenceStore.allKeys)
        let shortcut = try XCTUnwrap(written[CapturePreferenceStore.shortcutKey] as? [String: Any])
        XCTAssertEqual(Set(shortcut.keys), ["enabled", "keyCode", "modifiers", "keyLabel"])

        // Malformed stored values are ignored rather than registered.
        defaults.set(["enabled": true, "keyCode": 99_999, "modifiers": 8, "keyLabel": "R"],
                     forKey: CapturePreferenceStore.shortcutKey)
        XCTAssertNil(store.shortcutPreference)
    }

    /// The shortcut uses Carbon hot keys only: no event taps, global monitors, or Accessibility.
    func testShortcutNeedsNoAccessibilityOrInputMonitoring() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("RedScreen/Capture/GlobalHotKey.swift"),
                              encoding: .utf8)
        XCTAssertTrue(text.contains("RegisterEventHotKey"))
        XCTAssertTrue(text.contains("kEventHotKeyExclusive"))
        for forbidden in ["CGEvent.tapCreate", "CGEventTapCreate", "addGlobalMonitorForEvents",
                          "AXIsProcessTrusted", "IOHIDRequestAccess"] {
            XCTAssertFalse(text.contains(forbidden), forbidden)
        }
        let settings = try String(contentsOf: root.appendingPathComponent("RedScreen/UI/SettingsView.swift"),
                                  encoding: .utf8)
        XCTAssertFalse(settings.contains("addGlobalMonitorForEvents"))
        XCTAssertFalse(settings.contains("CGWindowListCreateImage"))
    }

    /// The system prompt can only come from the permission model's capture path.
    func testScreenRecordingPromptIsRequestedOnlyByTheCapturePath() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: root.appendingPathComponent("RedScreen"), includingPropertiesForKeys: nil
        ))
        var requesters: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains("CGRequestScreenCaptureAccess") { requesters.append(url.lastPathComponent) }
        }
        XCTAssertEqual(requesters, ["ScreenCaptureKitService.swift"], "Only the system authorizer may request access")
    }
}
