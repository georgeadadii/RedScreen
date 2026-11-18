import Foundation

// Generates the synthetic RedScreen fixture corpus.
//
// Usage: fixture-generator <output-directory>
//
// Run it through `make fixtures`, which builds this tool together with the shared files in
// RedScreenCoreTests/FixtureSupport and executes it with an empty environment inside the sandbox
// profile in generator.sb (no network, no reads of the home directory, writes only beneath the
// output directory). The tool's only inputs are the compiled-in scenarios and its single
// command-line argument.

struct FixtureCorpusGenerator {
    let renderer = FixtureRenderer()

    func write(to outputDirectory: URL) throws {
        let imagesDirectory = outputDirectory.appendingPathComponent("images", isDirectory: true)
        let groundTruthDirectory = outputDirectory.appendingPathComponent(
            "ground-truth", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: imagesDirectory, withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: groundTruthDirectory, withIntermediateDirectories: true
        )

        let encoder = FixtureJSON.encoder()
        var entries: [FixtureManifestEntry] = []
        for scenario in FixtureScenarios.all {
            for scale in FixtureScenarios.scales {
                let rendered = try renderer.render(scenario, scale: scale)
                let id = rendered.groundTruth.id
                let imagePath = "images/\(id).png"
                let groundTruthPath = "ground-truth/\(id).json"
                let groundTruthData = try encoder.encode(rendered.groundTruth) + Data("\n".utf8)

                try rendered.png.write(to: outputDirectory.appendingPathComponent(imagePath))
                try groundTruthData.write(
                    to: outputDirectory.appendingPathComponent(groundTruthPath)
                )
                entries.append(FixtureManifestEntry(
                    id: id,
                    image: imagePath,
                    groundTruth: groundTruthPath,
                    imageSHA256: FixtureDigest.sha256Hex(rendered.png),
                    groundTruthSHA256: FixtureDigest.sha256Hex(groundTruthData)
                ))
            }
        }

        let manifest = FixtureManifest(
            schemaVersion: FixtureSchema.version,
            notice: FixtureSchema.notice,
            entries: entries.sorted { $0.id < $1.id }
        )
        try (encoder.encode(manifest) + Data("\n".utf8)).write(
            to: outputDirectory.appendingPathComponent("manifest.json")
        )
        print("Wrote \(entries.count) synthetic fixtures.")
    }
}

let arguments = CommandLine.arguments
guard arguments.count == 2, arguments[1].hasPrefix("/") else {
    FileHandle.standardError.write(Data("usage: fixture-generator <absolute-output-dir>\n".utf8))
    exit(64)
}

do {
    try FixtureCorpusGenerator().write(to: URL(fileURLWithPath: arguments[1], isDirectory: true))
} catch {
    FileHandle.standardError.write(Data("fixture generation failed: \(error)\n".utf8))
    exit(1)
}
