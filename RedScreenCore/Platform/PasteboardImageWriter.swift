import AppKit

/// Places a flattened redacted image on a pasteboard.
@MainActor
public protocol RedactedImageClipboard {
    func copy(_ image: FlattenedRedactedImage) throws
}

/// Writes one pasteboard item holding only scrubbed PNG data of the rendered bitmap.
///
/// No file URL, string, source representation, or custom type carrying review data is written.
/// macOS may additionally offer system-generated TIFF translations to readers; those are derived
/// on demand from this PNG, not from the source. Encoding happens before the pasteboard is
/// cleared, so a failure leaves the user's previous clipboard untouched.
@MainActor
public struct PasteboardImageWriter: RedactedImageClipboard {
    /// The complete set of types this writer declares.
    public static let approvedTypes: [NSPasteboard.PasteboardType] = [.png]

    private let pasteboard: NSPasteboard
    private let encoder: any RedactedImageEncoding

    public init(pasteboard: NSPasteboard = .general, encoder: any RedactedImageEncoding = ScrubbedPNGEncoder()) {
        self.pasteboard = pasteboard
        self.encoder = encoder
    }

    public func copy(_ image: FlattenedRedactedImage) throws {
        let data: Data
        do {
            data = try encoder.encode(image)
        } catch {
            throw ImageExportError.encodingFailed
        }
        let item = NSPasteboardItem()
        guard item.setData(data, forType: .png) else { throw ImageExportError.clipboardFailed }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            pasteboard.clearContents()
            throw ImageExportError.clipboardFailed
        }
    }
}
