import AppKit
import SwiftUI

/// Hosts the document view in an AppKit window created on demand.
///
/// Using AppKit here keeps the menu bar app window-free at launch and lets the window opt out of
/// state restoration, so no screenshot-bearing window state is written by the system. Closing the
/// window closes the document and clears its session.
@MainActor
final class DocumentWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    private weak var model: AppModel?

    init(model: AppModel) {
        self.model = model
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: true
        )
        super.init()

        window.title = "RedScreen"
        window.identifier = NSUserInterfaceItemIdentifier("redscreen-document-window")
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.contentMinSize = NSSize(width: 720, height: 420)
        window.contentViewController = NSHostingController(rootView: DocumentView(model: model))
        window.setContentSize(NSSize(width: 900, height: 620))
        window.center()
        window.delegate = self
    }

    func present() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model?.closeDocument()
    }
}
