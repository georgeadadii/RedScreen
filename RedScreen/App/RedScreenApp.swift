import AppKit
import SwiftUI

@main
struct RedScreenApp: App {
    var body: some Scene {
        MenuBarExtra("RedScreen", systemImage: "shield.lefthalf.filled") {
            MenuBarContentView(
                showAbout: showAbout,
                quit: quit
            )
        }
        .menuBarExtraStyle(.window)
    }

    private func showAbout() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.orderFrontStandardAboutPanel(nil)
    }

    private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
