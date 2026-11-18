import Darwin
import Foundation

/// Saves a flattened redacted image to a user-selected file, atomically.
///
/// The encoded PNG is first written to a fresh staging directory on the destination's volume,
/// then moved into place with a single `rename`. Readers see either the previous file or the
/// complete new one, never a partial write. An existing file is replaced only when the
/// destination says the user confirmed it, and even then the no-replace path uses
/// `RENAME_EXCL`, so a file appearing after confirmation is never silently overwritten.
/// The staging directory is removed on success, failure, and cancellation. Nothing is logged.
public struct AtomicFileImageExporter: ImageExporter {
    public typealias StagingDirectoryProvider = @Sendable (_ destination: URL) throws -> URL

    private let encoder: any RedactedImageEncoding
    private let makeStagingDirectory: StagingDirectoryProvider

    public init(
        encoder: any RedactedImageEncoding = ScrubbedPNGEncoder(),
        stagingDirectory: @escaping StagingDirectoryProvider = AtomicFileImageExporter.systemStagingDirectory
    ) {
        self.encoder = encoder
        self.makeStagingDirectory = stagingDirectory
    }

    /// A new item-replacement directory on the same volume as `destination`.
    public static let systemStagingDirectory: StagingDirectoryProvider = { destination in
        try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: destination.deletingLastPathComponent(),
            create: true
        )
    }

    public func export(_ image: FlattenedRedactedImage, to destination: ExportDestination) async throws {
        try Task.checkCancellation()
        let url = destination.url
        guard url.isFileURL, !url.hasDirectoryPath else { throw ImageExportError.invalidDestination }

        let data: Data
        do {
            data = try encoder.encode(image)
        } catch {
            throw ImageExportError.encodingFailed
        }
        try Task.checkCancellation()
        if !destination.replacesExistingItem, Self.itemExists(at: url) {
            throw ImageExportError.destinationExists
        }

        let staging: URL
        do {
            staging = try makeStagingDirectory(url)
        } catch {
            throw ImageExportError.writeFailed
        }
        defer { try? FileManager.default.removeItem(at: staging) }

        let staged = staging.appendingPathComponent("\(UUID().uuidString).png", isDirectory: false)
        do {
            try data.write(to: staged, options: .withoutOverwriting)
        } catch {
            throw ImageExportError.writeFailed
        }
        try Task.checkCancellation()

        let status = staged.withUnsafeFileSystemRepresentation { source in
            url.withUnsafeFileSystemRepresentation { target -> Int32 in
                guard let source, let target else { return -1 }
                return destination.replacesExistingItem
                    ? rename(source, target)
                    : renamex_np(source, target, UInt32(RENAME_EXCL))
            }
        }
        guard status == 0 else {
            throw errno == EEXIST ? ImageExportError.destinationExists : ImageExportError.writeFailed
        }
    }

    private static func itemExists(at url: URL) -> Bool {
        var info = stat()
        return url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return lstat(path, &info) == 0
        }
    }
}
