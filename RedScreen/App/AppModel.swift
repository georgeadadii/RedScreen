import AppKit
import Observation
import RedScreenCore
import UniformTypeIdentifiers

/// Composition root: owns the single secure lifecycle, the importer, and the document window.
@MainActor
@Observable
final class AppModel {
    let importController: ScreenshotImportController

    @ObservationIgnored private var documentWindowController: DocumentWindowController?

    init() {
        importController = ScreenshotImportController(
            lifecycle: SecureImageSessionLifecycle(),
            importer: ImageIOImageImporter(),
            screenCapturer: ScreenCaptureKitService(),
            textRecognizer: VisionTextRecognizer(),
            secretDetector: ContextualSecretDetector(),
            candidateComposer: GeometricCandidateComposer(),
            imageExporter: AtomicFileImageExporter(),
            clipboard: PasteboardImageWriter()
        )
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
        Task { await runCapture(kind) }
    }

    private func runCapture(_ kind: CaptureKind) async {
        let target: CaptureTarget
        switch kind {
        case .region:
            // Hide the document window so the user selects what is actually on screen.
            let wasVisible = documentWindowController?.window.isVisible == true
            documentWindowController?.window.orderOut(nil)
            let selection = await RegionSelectionOverlay.select()
            switch selection {
            case .success(let rect):
                target = .region(rect)
            case .failure(let error):
                if wasVisible || error != .canceled { showDocumentWindow() }
                importController.reportCaptureFailure(error)
                return
            }
        case .window:
            do {
                let choices = try await ScreenCaptureKitService.windowChoices()
                guard !choices.isEmpty else { throw CaptureError.targetUnavailable }
                guard let id = choose(from: choices, title: "Capture Window") else { return }
                target = .window(id: id)
            } catch {
                showDocumentWindow()
                importController.reportCaptureFailure(error as? CaptureError ?? .failed)
                return
            }
        case .display:
            let displays = ScreenCaptureKitService.currentDisplays()
            if displays.count == 1, let only = displays.first {
                target = .display(id: only.id)
            } else {
                let mainID = CGMainDisplayID()
                let choices = displays.enumerated().map { index, display in
                    (display.id, "Display \(index + 1)\(display.id == mainID ? " (main)" : "") — "
                        + "\(Int(display.frame.width)) × \(Int(display.frame.height)) pt @\(Int(display.scale))x")
                }
                guard let id = choose(from: choices, title: "Capture Display") else { return }
                target = .display(id: id)
            }
        }
        showDocumentWindow()
        importController.captureScreenshot(target)
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
