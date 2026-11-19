import AppKit
import RedScreenCore

/// What the user chose in the selection overlay.
enum CaptureSelection: Equatable {
    /// A dragged rectangle in Core Graphics global points.
    case region(CGRect)
    /// Return or D: the whole display under the pointer.
    case display(id: UInt32)
    /// W: switch to choosing a window from a menu.
    case chooseWindow
}

/// Lets the user drag out a capture region across any display, or pick another mode by key.
///
/// One borderless panel covers each screen and shows the mode hint. The panels are live dimming
/// only: nothing on screen is captured or kept to draw them, they are excluded from capture
/// (`sharingType = .none`), never become the main window, and close as soon as the selection
/// ends. Escape or a right-click cancels; a display change ends the selection with
/// `.displayConfigurationChanged`.
///
/// Return (or D) captures the display under the pointer and W switches to window choice, so a
/// capture can be made entirely from the keyboard and with VoiceOver.
@MainActor
final class RegionSelectionOverlay {
    static let hint = "Drag to capture a region. Return: whole display · W: choose a window · Esc: cancel"

    private var panels: [NSPanel] = []
    private var continuation: CheckedContinuation<Result<CaptureSelection, CaptureError>, Never>?
    private var screenObserver: (any NSObjectProtocol)?
    private var previousActivationPolicy: NSApplication.ActivationPolicy?
    fileprivate var anchor: NSPoint?
    fileprivate var current: NSPoint?

    static func select() async -> Result<CaptureSelection, CaptureError> {
        let overlay = RegionSelectionOverlay()
        return await withCheckedContinuation { continuation in
            overlay.begin(continuation)
        }
    }

    /// The selection in AppKit global coordinates.
    fileprivate var selection: NSRect? {
        guard let anchor, let current else { return nil }
        return NSRect(x: min(anchor.x, current.x), y: min(anchor.y, current.y),
                      width: abs(anchor.x - current.x), height: abs(anchor.y - current.y))
    }

    private func begin(_ continuation: CheckedContinuation<Result<CaptureSelection, CaptureError>, Never>) {
        self.continuation = continuation
        guard !NSScreen.screens.isEmpty else {
            finish(.failure(.targetUnavailable))
            return
        }
        for screen in NSScreen.screens {
            let panel = SelectionPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                       backing: .buffered, defer: false)
            panel.level = .screenSaver
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.sharingType = .none
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.setFrame(screen.frame, display: false)
            panel.contentView = SelectionView(overlay: self)
            panel.setAccessibilityLabel("Screen capture selection. \(Self.hint)")
            panels.append(panel)
            panel.orderFrontRegardless()
        }
        NSApp.activate()
        panels.first?.makeKey()
        NSCursor.crosshair.push()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(.failure(.displayConfigurationChanged)) }
        }
    }

    fileprivate func update(to point: NSPoint, starting: Bool) {
        if starting { anchor = point }
        current = point
        panels.forEach { $0.contentView?.needsDisplay = true }
    }

    fileprivate func complete() {
        guard let selection, selection.width >= 1, selection.height >= 1,
              let main = NSScreen.screens.first else {
            finish(.failure(.emptyRegion))
            return
        }
        let rect = CaptureGeometry.coreGraphicsRect(fromAppKit: selection, mainDisplayHeight: main.frame.height)
        finish(.success(.region(rect)))
    }

    fileprivate func captureDisplayUnderPointer() {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        guard let id = screen?.displayID else {
            finish(.failure(.targetUnavailable))
            return
        }
        finish(.success(.display(id: id)))
    }

    fileprivate func chooseWindow() {
        finish(.success(.chooseWindow))
    }

    fileprivate func cancel() {
        finish(.failure(.canceled))
    }

    private func finish(_ result: Result<CaptureSelection, CaptureError>) {
        guard let continuation else { return }
        self.continuation = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        NSCursor.pop()
        panels.forEach { $0.orderOut(nil); $0.close() }
        panels.removeAll()
        continuation.resume(returning: result)
    }
}

private final class SelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class SelectionView: NSView {
    private weak var overlay: RegionSelectionOverlay?

    init(overlay: RegionSelectionOverlay) {
        self.overlay = overlay
        super.init(frame: .zero)

        let hint = NSTextField(labelWithString: RegionSelectionOverlay.hint)
        hint.textColor = .white
        hint.font = .systemFont(ofSize: NSFont.systemFontSize + 1, weight: .medium)
        hint.drawsBackground = true
        hint.backgroundColor = NSColor.black.withAlphaComponent(0.72)
        hint.alignment = .center
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.setAccessibilityIdentifier("capture-selection-hint")
        addSubview(hint)
        NSLayoutConstraint.activate([
            hint.centerXAnchor.constraint(equalTo: centerXAnchor),
            hint.topAnchor.constraint(equalTo: topAnchor, constant: 64),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        overlay?.update(to: screenPoint(event), starting: true)
    }

    override func mouseDragged(with event: NSEvent) {
        overlay?.update(to: screenPoint(event), starting: false)
    }

    override func mouseUp(with event: NSEvent) {
        overlay?.update(to: screenPoint(event), starting: false)
        overlay?.complete()
    }

    override func rightMouseDown(with event: NSEvent) {
        overlay?.cancel()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: overlay?.cancel()  // Escape
        case 36, 76, 2: overlay?.captureDisplayUnderPointer()  // Return, Enter, D
        case 13: overlay?.chooseWindow()  // W
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        overlay?.cancel()
    }

    private func screenPoint(_ event: NSEvent) -> NSPoint {
        window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.3).setFill()
        bounds.fill()
        guard let window, let selection = overlay?.selection else { return }
        let local = window.convertFromScreen(selection)
        guard local.intersects(bounds) else { return }
        NSColor.clear.setFill()
        local.fill(using: .copy)
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: local.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()
    }
}
