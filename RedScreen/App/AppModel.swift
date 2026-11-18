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
            textRecognizer: VisionTextRecognizer(),
            secretDetector: ContextualSecretDetector()
        )
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

    func importDroppedItems(_ urls: [URL]) {
        showDocumentWindow()
        importController.importDroppedItems(urls)
    }

    /// Clears the open document and every session artifact.
    func closeDocument() {
        importController.closeDocument()
    }

    @discardableResult
    private func showDocumentWindow() -> NSWindow {
        let controller = documentWindowController ?? DocumentWindowController(model: self)
        documentWindowController = controller
        controller.present()
        return controller.window
    }
}
