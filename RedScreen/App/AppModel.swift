import AppKit
import Observation
import RedScreenCore
import UniformTypeIdentifiers

/// Composition root: owns the single secure lifecycle, the importer, the capture permission and
/// shortcut state, and the document window.
@MainActor
@Observable
final class AppModel {
    let importController: ScreenshotImportController
    let permission: CapturePermissionModel
    /// Created in `init`; never nil afterwards.
    private(set) var shortcut: GlobalShortcutController!

    /// True while the user records a new shortcut, so pressing the current one does not capture.
    var isRecordingShortcut = false

    @ObservationIgnored private var documentWindowController: DocumentWindowController?
    @ObservationIgnored private var isChoosingTarget = false
    @ObservationIgnored private var activationObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var terminationObserver: (any NSObjectProtocol)?

    init() {
        var capturer: any ScreenCaptureService = ScreenCaptureKitService()
        var authorizer: any ScreenRecordingAuthorizing = SystemScreenRecordingAuthorizer()
        var registrar: any GlobalHotKeyRegistering = CarbonHotKeyRegistrar()
        var systemShortcuts: any SystemShortcutCatalog = SymbolicHotKeyCatalog()
        let preferences = CapturePreferenceStore()
        var permissionRecord: any PermissionRequestRecord = preferences
        var shortcutStore: any GlobalShortcutPreferenceStore = preferences
        #if DEBUG
        if UITestHooks.usesFakeCapture { capturer = FakeScreenCaptureService() }
        if let state = UITestHooks.permission {
            authorizer = FakeScreenRecordingAuthorizer(state)
            permissionRecord = InMemoryCapturePreferences(hasRequested: state != .notDetermined)
        }
        if UITestHooks.usesFakeShortcuts {
            registrar = FakeHotKeyRegistrar()
            systemShortcuts = FakeSystemShortcutCatalog()
            shortcutStore = InMemoryCapturePreferences(hasRequested: false)
        }
        #endif

        importController = ScreenshotImportController(
            lifecycle: SecureImageSessionLifecycle(),
            importer: ImageIOImageImporter(),
            screenCapturer: capturer,
            textRecognizer: VisionTextRecognizer(),
            secretDetector: ContextualSecretDetector(),
            candidateComposer: GeometricCandidateComposer(),
            imageExporter: AtomicFileImageExporter(),
            clipboard: PasteboardImageWriter()
        )
        permission = CapturePermissionModel(authorizer: authorizer, record: permissionRecord)
        // A granted permission makes any "Screen Recording is off" banner obsolete.
        permission.onGranted = { [weak importController] in importController?.clearPermissionFailure() }
        #if DEBUG
        if UITestHooks.permission == .restricted { permission.noteRestricted() }
        #endif
        shortcut = GlobalShortcutController(
            registrar: registrar, systemShortcuts: systemShortcuts, store: shortcutStore
        ) { [weak self] in
            self?.captureFromShortcut()
        }
        // Registers nothing unless the user turned the shortcut on in an earlier launch.
        shortcut.restore()

        // Picks up a change the user made in System Settings, without prompting.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.permission.refresh() }
        }
        // Clears the open document's in-memory pixels and text before the process exits.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.importController.closeDocument() }
        }
    }

    func openScreenRecordingSettings() {
        NSWorkspace.shared.open(ScreenRecordingPermission.systemSettingsURL)
    }

    /// Asks for a destination and saves exactly `image`. Returns false if the user cancels.
    ///
    /// The suggested name is generic, never the source filename. The Save panel confirms any
    /// replacement; only then is the exporter allowed to replace an existing file. The URL is not
    /// retained after this call.
    func saveRedactedImage(_ image: FlattenedRedactedImage) async throws -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Redacted Screenshot.png"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.prompt = "Save"
        panel.message = "Saves the flattened redacted image as PNG without the original's metadata."
        let response: NSApplication.ModalResponse
        if let window = documentWindowController?.window {
            response = await withCheckedContinuation { continuation in
                panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        } else {
            response = panel.runModal()
        }
        guard response == .OK, let url = panel.url else { return false }
        let replaces = FileManager.default.fileExists(atPath: url.path)
        try await importController.exportReviewedImage(
            image, to: ExportDestination(url: url, replacesExistingItem: replaces)
        )
        return true
    }

    /// Shows the document window and presents an Open panel for one PNG, JPEG, or HEIC file.
    func chooseScreenshot() {
        let window = showDocumentWindow()

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .heif]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.resolvesAliases = true
        panel.prompt = "Import"
        panel.message = "Choose a screenshot to redact. It stays on this Mac."
        panel.beginSheetModal(for: window) { [weak self, weak panel] response in
            guard response == .OK, let url = panel?.url else { return }
            self?.importController.importImage(from: url)
        }
    }

    enum CaptureKind { case region, window, display }

    /// Starts a user-initiated capture. Choosing a target happens here, in the app target;
    /// canceling at any point leaves the open document as it was.
    func capture(_ kind: CaptureKind) {
        guard !isChoosingTarget else { return }
        isChoosingTarget = true
        Task { await runCapture(kind) }
    }

    /// The global shortcut starts a region selection, whose overlay also offers the whole
    /// display (Return) and window choice (W).
    private func captureFromShortcut() {
        guard !isRecordingShortcut else { return }
        capture(.region)
    }

    private func runCapture(_ kind: CaptureKind) async {
        guard let target = await chooseTarget(kind) else {
            isChoosingTarget = false
            return
        }
        isChoosingTarget = false
        showDocumentWindow()
        await importController.captureScreenshot(target)?.value
        switch importController.lastCaptureError {
        case .permissionRestricted: permission.noteRestricted()
        case .permissionDenied: permission.refresh()
        default: break
        }
    }

    /// Returns the target to capture, or nil after reporting a failure or a cancellation.
    private func chooseTarget(_ kind: CaptureKind) async -> CaptureTarget? {
        // The only place the Screen Recording prompt can be requested, and only once ever.
        guard permission.authorizeCapture() else {
            showDocumentWindow()
            importController.reportCaptureFailure(permission.blockedCaptureError)
            return nil
        }
        switch kind {
        case .region:
            // Hide the document window so the user selects what is actually on screen.
            let wasVisible = documentWindowController?.window.isVisible == true
            documentWindowController?.window.orderOut(nil)
            switch await RegionSelectionOverlay.select() {
            case .success(.region(let rect)):
                return .region(rect)
            case .success(.display(let id)):
                return .display(id: id)
            case .success(.chooseWindow):
                return await chooseWindowTarget(restoringWindow: wasVisible)
            case .failure(let error):
                if wasVisible || error != .canceled { showDocumentWindow() }
                importController.reportCaptureFailure(error)
                return nil
            }
        case .window:
            return await chooseWindowTarget(restoringWindow: false)
        case .display:
            let displays = ScreenCaptureKitService.currentDisplays()
            if displays.count == 1, let only = displays.first { return .display(id: only.id) }
            let mainID = CGMainDisplayID()
            let choices = displays.enumerated().map { index, display in
                (display.id, "Display \(index + 1)\(display.id == mainID ? " (main)" : "") — "
                    + "\(Int(display.frame.width)) × \(Int(display.frame.height)) pt @\(Int(display.scale))x")
            }
            guard let id = choose(from: choices, title: "Capture Display") else { return nil }
            return .display(id: id)
        }
    }

    private func chooseWindowTarget(restoringWindow: Bool) async -> CaptureTarget? {
        do {
            let choices = try await ScreenCaptureKitService.windowChoices()
            guard !choices.isEmpty else { throw CaptureError.targetUnavailable }
            guard let id = choose(from: choices, title: "Capture Window") else {
                if restoringWindow { showDocumentWindow() }
                return nil
            }
            return .window(id: id)
        } catch {
            showDocumentWindow()
            importController.reportCaptureFailure(error as? CaptureError ?? .failed)
            return nil
        }
    }

    /// Shows a menu of targets at the pointer and returns the chosen ID, or nil if dismissed.
    /// Labels live only in this transient menu.
    private func choose(from choices: [(id: UInt32, label: String)], title: String) -> UInt32? {
        let menu = NSMenu(title: title)
        let picker = MenuPicker()
        for choice in choices {
            let item = NSMenuItem(title: choice.label, action: #selector(MenuPicker.pick(_:)), keyEquivalent: "")
            item.target = picker
            item.tag = Int(choice.id)
            menu.addItem(item)
        }
        NSApp.activate()
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        return picker.chosen
    }

    func importDroppedItems(_ urls: [URL]) {
        showDocumentWindow()
        importController.importDroppedItems(urls)
    }

    /// Clears the open document and every session artifact.
    func closeDocument() {
        importController.closeDocument()
    }

    @discardableResult
    func showDocumentWindow() -> NSWindow {
        let controller = documentWindowController ?? DocumentWindowController(model: self)
        documentWindowController = controller
        controller.present()
        return controller.window
    }
}

@MainActor
private final class MenuPicker: NSObject {
    var chosen: UInt32?

    @objc func pick(_ sender: NSMenuItem) {
        chosen = UInt32(truncatingIfNeeded: sender.tag)
    }
}
