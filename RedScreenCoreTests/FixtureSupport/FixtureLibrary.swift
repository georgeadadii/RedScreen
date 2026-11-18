import Foundation
import ImageIO
import RedScreenCore

/// Loads the synthetic fixture corpus bundled into RedScreenCoreTests.
///
/// The corpus lives in `RedScreenCoreTests/Fixtures` and is copied into the test bundle as a folder
/// reference. Nothing here reads outside the test bundle or touches the network.
struct FixtureLibrary {
    enum LoadError: Error, Equatable, CustomStringConvertible {
        case corpusMissing
        case fileMissing(String)
        case unknownFixture(String)
        case imageUndecodable(String)

        var description: String {
            switch self {
            case .corpusMissing: "The Fixtures folder is missing from the test bundle"
            case .fileMissing(let path): "Fixture file \(path) is missing"
            case .unknownFixture(let id): "No fixture with ID \(id)"
            case .imageUndecodable(let id): "Fixture image \(id) could not be decoded"
            }
        }
    }

    let rootURL: URL
    let manifest: FixtureManifest

    static func bundled() throws -> FixtureLibrary {
        guard let rootURL = Bundle(for: FixtureBundleToken.self)
            .url(forResource: "Fixtures", withExtension: nil) else {
            throw LoadError.corpusMissing
        }
        return try FixtureLibrary(rootURL: rootURL)
    }

    init(rootURL: URL) throws {
        self.rootURL = rootURL
        let manifestURL = rootURL.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL) else {
            throw LoadError.fileMissing("manifest.json")
        }
        manifest = try FixtureJSON.decoder().decode(FixtureManifest.self, from: data)
    }

    func fixtures() throws -> [LoadedFixture] {
        try manifest.entries.map(load)
    }

    func fixture(id: String) throws -> LoadedFixture {
        guard let entry = manifest.entries.first(where: { $0.id == id }) else {
            throw LoadError.unknownFixture(id)
        }
        return try load(entry)
    }

    func data(atRelativePath path: String) throws -> Data {
        guard let data = try? Data(contentsOf: rootURL.appendingPathComponent(path)) else {
            throw LoadError.fileMissing(path)
        }
        return data
    }

    /// Every regular file in the corpus, as paths relative to the corpus root.
    func allRelativeFilePaths() throws -> Set<String> {
        let rootPath = rootURL.standardizedFileURL.resolvingSymlinksInPath().path
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            throw LoadError.corpusMissing
        }
        var paths: Set<String> = []
        for case let url as URL in enumerator {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                continue
            }
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            paths.insert(String(path.dropFirst(rootPath.count + 1)))
        }
        return paths
    }

    private func load(_ entry: FixtureManifestEntry) throws -> LoadedFixture {
        let groundTruth = try FixtureJSON.decoder().decode(
            FixtureGroundTruth.self,
            from: data(atRelativePath: entry.groundTruth)
        )
        return LoadedFixture(
            entry: entry,
            groundTruth: groundTruth,
            imageURL: rootURL.appendingPathComponent(entry.image)
        )
    }
}

struct LoadedFixture {
    let entry: FixtureManifestEntry
    let groundTruth: FixtureGroundTruth
    let imageURL: URL

    var id: String { entry.id }

    func imageData() throws -> Data {
        guard let data = try? Data(contentsOf: imageURL) else {
            throw FixtureLibrary.LoadError.fileMissing(entry.image)
        }
        return data
    }

    /// Decoded pixel size of the PNG, read with ImageIO without retaining the bitmap.
    func decodedPixelSize() throws -> (width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw FixtureLibrary.LoadError.imageUndecodable(id)
        }
        return (width, height)
    }
}

private final class FixtureBundleToken {}

// MARK: - Bridging to RedScreenCore geometry

extension FixtureRect {
    func normalizedRect() throws -> NormalizedRect {
        try NormalizedRect(x: x, y: y, width: width, height: height)
    }

    func imageRect(in dimensions: PixelDimensions) throws -> ImageRect {
        try ImageRect(
            normalized: normalizedRect(),
            dimensions: dimensions,
            sourceOrigin: .topLeft
        )
    }
}

extension FixtureGroundTruth {
    func pixelDimensions() throws -> PixelDimensions {
        try PixelDimensions(width: pixelWidth, height: pixelHeight)
    }

    func textBox(id: String) -> FixtureTextBox? {
        textBoxes.first { $0.id == id }
    }

    /// The substring a segment labels, or nil when its offsets fall outside its text box.
    func text(of segment: FixtureSpanSegment) -> String? {
        guard let box = textBox(id: segment.textBoxID),
              segment.utf16Offset >= 0,
              segment.utf16Length > 0,
              segment.utf16Offset + segment.utf16Length <= box.text.utf16.count else {
            return nil
        }
        let utf16 = box.text.utf16
        let start = utf16.index(utf16.startIndex, offsetBy: segment.utf16Offset)
        let end = utf16.index(start, offsetBy: segment.utf16Length)
        return String(utf16[start..<end])
    }

    /// The full labelled value, joining wrapped segments without separators.
    func text(of span: FixtureSpan) -> String? {
        var result = ""
        for segment in span.segments {
            guard let text = text(of: segment) else { return nil }
            result += text
        }
        return result
    }
}
