import AppKit
import RedScreenCore
import SwiftUI

/// RedScreen's Settings window: the optional global capture shortcut and the Screen Recording
/// state. Nothing here shows or keeps an image of the screen or of other apps' windows.
struct SettingsView: View {
    let model: AppModel

    var body: some View {
        Form {
            Section("Capture Shortcut") {
                ShortcutSettings(model: model, controller: model.shortcut)
            }
            Section("Screen Recording") {
                PermissionGuidanceView(model: model, style: .settings)
            }
            Section("VS Code Hints") {
                EditorHintSettings(model: model, bridge: model.editorHints)
            }
            Section("Without the Shortcut") {
                Text("Capture from the RedScreen menu bar item, or from the Capture menu while a "
                     + "RedScreen window is open: Region ⌥⌘1, Window ⌥⌘2, Display ⌥⌘3. In the region "
                     + "selection, press Return for the whole display, W to choose a window, or Esc to cancel.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings-capture-alternatives")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { model.permission.refresh() }
    }
}

private struct ShortcutSettings: View {
    let model: AppModel
    let controller: GlobalShortcutController

    @State private var recorder = ShortcutRecorder()

    var body: some View {
        Toggle("Start a capture with a keyboard shortcut", isOn: Binding(
            get: { controller.isEnabled },
            set: { isOn in if isOn { controller.enable() } else { controller.disable() } }
        ))
        .accessibilityIdentifier("shortcut-enabled-toggle")

        HStack {
            Text("Shortcut")
            Spacer()
            Text(recorder.isRecording ? "Type a shortcut…" : controller.displayedShortcut.displayString)
                .font(.body.monospaced())
                .foregroundStyle(controller.isEnabled ? .primary : .secondary)
                .accessibilityLabel(recorder.isRecording
                    ? "Recording. Type a shortcut, or press Escape to cancel."
                    : controller.displayedShortcut.accessibilityDescription)
                .accessibilityIdentifier("shortcut-display")
            Button(recorder.isRecording ? "Cancel" : "Change…") {
                if recorder.isRecording { stopRecording() } else { startRecording() }
            }
            .accessibilityIdentifier("shortcut-change-button")
            Button("Use Default") { controller.enable(.documentedDefault) }
                .disabled(controller.status == .active(.documentedDefault))
                .help("Use \(GlobalShortcut.documentedDefault.displayString)")
                .accessibilityIdentifier("shortcut-default-button")
        }

        if let message = problemMessage {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("shortcut-problem-message")
        }

        Text("Starts a region selection from any app. RedScreen never takes a shortcut that macOS or "
             + "another app already uses; it keeps your previous one instead. The shortcut needs no "
             + "Accessibility or Input Monitoring permission and sees no other typing.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var problemMessage: String? {
        if let rejection = controller.lastRejection {
            return "\(rejection.shortcut.displayString) wasn't set. \(rejection.error.userMessage)"
        }
        if case .unavailable(let shortcut, let error) = controller.status {
            return "\(shortcut.displayString) isn't active. \(error.userMessage)"
        }
        return nil
    }

    private func startRecording() {
        model.isRecordingShortcut = true
        recorder.start { shortcut in
            stopRecording()
            if let shortcut { controller.enable(shortcut) }
        }
    }

    private func stopRecording() {
        recorder.stop()
        model.isRecordingShortcut = false
    }
}

/// The optional VS Code hint listener: off by default, with its status and what it shares.
private struct EditorHintSettings: View {
    @Bindable var model: AppModel
    let bridge: EditorHintBridge

    var body: some View {
        Toggle("Accept hints from the RedScreen VS Code extension", isOn: $model.acceptsEditorHints)
            .accessibilityIdentifier("editor-hints-toggle")
        LabeledContent("Status") {
            Text(statusText)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("editor-hints-status")
        }
        if bridge.isRunning {
            LabeledContent("Pairing file") {
                Text(bridge.pairingURL.path)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
        Text("When on, the extension can tell RedScreen which secrets are in your active editor, so "
             + "matching findings in your next capture are confirmed. It sends only keyed fingerprints, "
             + "never values, text, or file names, over a private connection on this Mac. Hints can only "
             + "confirm findings, never hide them, and RedScreen works the same without them.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var statusText: String {
        switch bridge.status {
        case .off: "Off"
        case .waiting: "Waiting for VS Code"
        case .connected(let count): count == 1 ? "Connected to VS Code" : "Connected to \(count) VS Code windows"
        case .unavailable: "Couldn't start. Turn it off and on again."
        }
    }
}

/// Records the next key press in RedScreen's own Settings window, with a local event monitor
/// that sees only events sent to RedScreen. Escape without modifiers cancels.
@MainActor
@Observable
final class ShortcutRecorder {
    private(set) var isRecording = false
    @ObservationIgnored private var monitor: Any?

    func start(_ completion: @escaping @MainActor (GlobalShortcut?) -> Void) {
        stop()
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
                if event.keyCode == 53, flags.isEmpty {
                    completion(nil)
                } else {
                    completion(GlobalShortcut(event: event))
                }
            }
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }
}

/// Explains the Screen Recording state and how to recover. "Open System Settings" appears only
/// when Settings can fix the state, and only opens it when the user clicks; nothing here prompts.
struct PermissionGuidanceView: View {
    enum Style { case settings, banner }

    let model: AppModel
    let style: Style

    var body: some View {
        let state = model.permission.state
        let guidance = state.guidance
        VStack(alignment: .leading, spacing: 6) {
            Label(guidance.title, systemImage: symbol(for: state))
                .font(style == .banner ? .headline : .body)
                .accessibilityIdentifier("permission-title")
            Text(guidance.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("permission-message")
            HStack {
                if guidance.offersSystemSettings {
                    Button("Open System Settings", action: model.openScreenRecordingSettings)
                        .accessibilityIdentifier("permission-open-settings")
                }
                if guidance.offersRequestAgain {
                    Button("Ask macOS Again") { model.permission.requestAgain() }
                        .help("Asks macOS for Screen Recording access again, which adds RedScreen back to "
                              + "the list in System Settings if it was removed.")
                        .accessibilityIdentifier("permission-request-again")
                }
                if state != .granted {
                    Button("Check Again", action: model.permission.checkAgain)
                        .accessibilityIdentifier("permission-check-again")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("permission-guidance")
    }

    private func symbol(for state: ScreenRecordingPermission) -> String {
        switch state {
        case .granted: "checkmark.circle.fill"
        case .notDetermined: "questionmark.circle"
        case .denied: "exclamationmark.triangle.fill"
        case .restricted: "lock.fill"
        }
    }
}
