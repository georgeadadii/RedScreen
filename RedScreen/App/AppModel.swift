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
