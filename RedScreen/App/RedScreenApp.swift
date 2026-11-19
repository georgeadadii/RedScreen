import AppKit
import SwiftUI

@main
struct RedScreenApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("RedScreen", systemImage: "shield.lefthalf.filled") {
            MenuBarContentView(
                importScreenshot: model.chooseScreenshot,
                capture: model.capture,
                importDroppedItems: model.importDroppedItems,
                shortcutHint: model.shortcut.isEnabled ? model.shortcut.displayedShortcut : nil,
                showAbout: showAbout,
                quit: quit
            )
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
        .commands {
            CaptureCommands(model: model)
        }
    }

    private func showAbout() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.orderFrontStandardAboutPanel(nil)
    }

    private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

/// The Capture menu in RedScreen's menu bar, shown while a RedScreen window is open. Every
/// command is reachable with the keyboard and VoiceOver through the standard menu bar.
struct CaptureCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandMenu("Capture") {
            Button("Capture Region…") { model.capture(.region) }
                .keyboardShortcut("1", modifiers: [.command, .option])
            Button("Capture Window…") { model.capture(.window) }
                .keyboardShortcut("2", modifiers: [.command, .option])
            Button("Capture Display") { model.capture(.display) }
                .keyboardShortcut("3", modifiers: [.command, .option])
            Divider()
            Button("Import Screenshot…", action: model.chooseScreenshot)
        }
    }
}
