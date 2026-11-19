import CoreGraphics
import Foundation
import XCTest

@testable import RedScreenCore

/// RED-14: detection profiles, custom rules, validation, and re-evaluation.
final class DetectionProfileTests: XCTestCase {
    private let team = DetectionProfile(
        name: "Team RSFAKE",
        likelyThreshold: 70,
        reviewThreshold: 35,
        disabledRules: ["provider.stripe-test-key"],
        placeholders: ["team-placeholder-token"],
        customRules: [
            CustomDetectionRule(id: "custom.team-token", kind: .token, prefix: "rsteam_", characters: .alphanumeric,
                                minimumLength: 20, maximumLength: 40, confidence: 90),
            CustomDetectionRule(id: "custom.team-secret", kind: .keyValue, keys: ["TEAM_VAULT_PASS", "vaultPass"],
                                minimumLength: 8, maximumLength: 64, confidence: 85),
        ]
    )

    // MARK: - Format

    func testRoundTripIsLosslessStableAndPlainText() throws {
        for profile in DetectionProfile.builtIns.map({ DetectionProfile(name: "Copy of \($0.name)", likelyThreshold: $0.likelyThreshold, reviewThreshold: $0.reviewThreshold) }) + [team] {
            let data = try DetectionProfileCodec.encode(profile)
            XCTAssertEqual(try DetectionProfileCodec.decode(data), profile)
            XCTAssertEqual(try DetectionProfileCodec.encode(DetectionProfileCodec.decode(data)), data, "Stable output")
        }
        let text = String(decoding: try DetectionProfileCodec.encode(team), as: UTF8.self)
        XCTAssertTrue(text.contains("\"format\" : \"redscreen-detection-profile\""))
        XCTAssertTrue(text.contains("\"version\" : 1"))
        XCTAssertEqual(Set(try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]).keys),
                       ["format", "version", "name", "thresholds", "disabledRules", "placeholders", "customRules"],
                       "Configuration only: no values, OCR text, screenshots, or history")
    }

    func testVersionsAndMalformedFilesFailWithActionableMessages() throws {
        func issues(_ text: String) -> [String] {
            do {
                _ = try DetectionProfileCodec.decode(Data(text.utf8))
                return []
            } catch let error as ProfileError {
                return error.issues
            } catch {
                return ["unexpected"]
            }
        }
        let valid = String(decoding: try DetectionProfileCodec.encode(team), as: UTF8.self)
        XCTAssertTrue(issues(valid.replacingOccurrences(of: "\"version\" : 1", with: "\"version\" : 2"))[0].contains("newer RedScreen"))
        XCTAssertTrue(issues(valid.replacingOccurrences(of: "\"version\" : 1", with: "\"version\" : 0"))[0].contains("not supported"))
        XCTAssertTrue(issues("{\"version\":1}")[0].contains("not a RedScreen detection profile"))
        XCTAssertTrue(issues("not json")[0].contains("not valid JSON"))
        XCTAssertTrue(issues(valid.replacingOccurrences(of: "\"name\"", with: "\"script\" : \"rm\", \"name\""))[0].contains("Unknown settings: script"))
        XCTAssertTrue(issues(String(repeating: " ", count: DetectionProfileCodec.maximumBytes + 1))[0].contains("larger than"))
        let tooMany = String(decoding: try JSONSerialization.data(withJSONObject: [
            "format": DetectionProfileCodec.format, "version": 1, "name": "Many", "thresholds": ["likely": 70, "review": 35],
            "customRules": Array(repeating: ["id": "custom.x", "kind": "token"], count: 65),
        ]), as: UTF8.self)
        XCTAssertTrue(issues(tooMany)[0].contains("at most 64 custom rules"))
    }

    // MARK: - Validation

    func testInvalidProfilesAreRejectedWithMessages() {
        func issues(_ change: (inout DetectionProfile) -> Void) -> [String] {
            var profile = team
            change(&profile)
            return DetectionProfileCodec.validate(profile)
        }
        XCTAssertEqual(DetectionProfileCodec.validate(team), [])
        let expectations: [(String, (inout DetectionProfile) -> Void)] = [
            ("name of 1–60", { $0.name = " " }),
            ("built-in profile name", { $0.name = "balanced" }),
            ("must not be above", { $0.reviewThreshold = 80 }),
            ("from 1 to 100", { $0.likelyThreshold = 0 }),
            ("Unknown built-in rules", { $0.disabledRules.insert("provider.made-up") }),
            ("3–64 characters", { $0.placeholders.append("ab") }),
            ("only once", { $0.placeholders.append("TEAM-PLACEHOLDER-TOKEN") }),
            ("\"custom.\" followed by", { $0.customRules[0].id = "acme" }),
            ("same ID", { $0.customRules[1].id = "custom.team-token" }),
            ("below the review threshold", { $0.customRules[0].confidence = 20 }),
            ("minimum length must be 8–256", { $0.customRules[0].minimumLength = 3 }),
            ("at least the minimum", { $0.customRules[0].maximumLength = 10 }),
            ("cannot match everywhere", { $0.customRules[0].prefix = "a" }),
            ("list 1–16 key names", { $0.customRules[1].keys = [] }),
            ("must be 2–64 letters", { $0.customRules[1].keys = ["a b"] }),
            ("belongs to a built-in rule", { $0.customRules[0].id = "provider.jwt" }),
            ("already matches prefix", { $0.customRules.append(CustomDetectionRule(
                id: "custom.dup", kind: .token, prefix: "RSTEAM_", characters: .alphanumeric,
                minimumLength: 10, maximumLength: 20, confidence: 90)) }),
        ]
        for (fragment, change) in expectations {
            let found = issues(change)
            XCTAssertTrue(found.contains { $0.contains(fragment) }, "Expected \"\(fragment)\" in \(found)")
        }
    }

    // MARK: - Matching

    private func observations(_ lines: [String]) -> [OCRObservation] {
        lines.enumerated().map { index, line in
            OCRObservation(text: line, boundingBox: try! NormalizedRect(x: 0.05, y: 0.02 + Double(index) * 0.05, width: 0.9, height: 0.04),
                           boundingBoxOrigin: .topLeft, confidence: try! Confidence(0.95))
        }
    }

    private func values(_ detections: [SecretDetection], _ input: [OCRObservation]) -> [String] {
        detections.map { detection in
            detection.spans.map { span in
                let text = input.first { $0.id == span.observationID }!.text
                return String(decoding: Array(text.utf16)[span.utf16Range], as: UTF16.self)
            }.joined()
        }
    }

    func testCustomRulesMatchTokensAndKeyValuesWithBoundaries() {
        let token = "rsteam_" + "RSFAKE0a1b2c3d4e5f6a7b8c9"
        let input = observations([
            "deploy with \(token) now",
            "xrsteam_RSFAKE0a1b2c3d4e5f6a7b8c9",  // no word boundary before the prefix
            "rsteam_RSFAKEtooshort",
            "rsteam_" + String(repeating: "A", count: 41),  // longer than the maximum
            "TEAM_VAULT_PASS=RSFAKE-vault-77",
            "{\"vaultPass\": \"RSFAKE-json-88\"}",
            "MY_TEAM_VAULT_PASS_OLD=RSFAKE-not-this",
            "TEAM_VAULT_PASS=team-placeholder-token",
        ])
        let detections = CustomRuleMatcher(rules: team.customRules, thresholds: team.thresholds)
            .detect(in: input, excludingPlaceholders: ["team-placeholder-token"])
        XCTAssertEqual(values(detections, input), [token, "RSFAKE-vault-77", "RSFAKE-json-88"])
        XCTAssertEqual(detections.map(\.evidence.ruleID.rawValue), ["custom.team-token", "custom.team-secret", "custom.team-secret"])
        XCTAssertEqual(detections.map(\.assessment), [.likely, .likely, .likely])
    }

    /// Adversarial text cannot make the matcher slow: it is linear, and input is capped.
    func testPathologicalInputStaysFast() {
        let rules = [
            CustomDetectionRule(id: "custom.aaa", kind: .token, prefix: "aaa", characters: .alphanumeric,
                                minimumLength: 256, maximumLength: 512, confidence: 90),
            CustomDetectionRule(id: "custom.kv", kind: .keyValue, keys: ["aa", "a_a"], minimumLength: 8, maximumLength: 512, confidence: 90),
        ]
        let hostile = [String(repeating: "a", count: 100_000), String(repeating: "aa=", count: 30_000),
                       String(repeating: "aaa_", count: 30_000), String(repeating: "a_a:\"", count: 30_000)]
        let input = observations(hostile)
        let started = Date()
        _ = CustomRuleMatcher(rules: rules, thresholds: .standard).detect(in: input)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
    }

    // MARK: - Profiles on the synthetic corpus (golden)

    private func corpus() throws -> [[OCRObservation]] {
        try FixtureLibrary.bundled().fixtures().map { fixture in
            try fixture.groundTruth.textBoxes.map { box in
                OCRObservation(text: box.text, boundingBox: try box.rect.normalizedRect(), boundingBoxOrigin: .topLeft,
                               confidence: try Confidence(1))
            }
        }
    }

    private func signature(_ detections: [SecretDetection]) -> [String] {
        detections.map { d in
            "\(d.evidence.ruleID.rawValue) \(d.assessment) " + d.spans.map { "\($0.observationID):\($0.utf16Range)" }.joined(separator: ",")
        }
    }

    func testBalancedReproducesTheNativeDetectorExactly() throws {
        var total = 0
        for input in try corpus() {
            let (profiled, report) = ProfiledSecretDetector(profile: .balanced).detect(in: input)
            XCTAssertEqual(signature(profiled), signature(ContextualSecretDetector().detect(in: input)))
            XCTAssertEqual(report.hiddenTotal, 0)
            total += profiled.count
        }
        XCTAssertGreaterThan(total, 40)
    }

    func testConservativeFindsEverythingBalancedDoesAndRedactsAtLeastAsMuch() throws {
        var balancedLikely = 0, conservativeLikely = 0
        for input in try corpus() {
            let balanced = ProfiledSecretDetector(profile: .balanced).detect(in: input).0
            let conservative = ProfiledSecretDetector(profile: .conservative).detect(in: input).0
            for finding in balanced {
                let spans = finding.spans
                let match = conservative.first { $0.spans == spans }
                XCTAssertNotNil(match, "Conservative lost \(finding.evidence.ruleID.rawValue)")
                if finding.assessment == .likely { XCTAssertEqual(match?.assessment, .likely) }
            }
            balancedLikely += balanced.filter { $0.assessment == .likely }.count
            conservativeLikely += conservative.filter { $0.assessment == .likely }.count
        }
        XCTAssertGreaterThanOrEqual(conservativeLikely, balancedLikely)
        XCTAssertFalse(DetectionProfile.conservative.reducesCoverage)
        XCTAssertFalse(DetectionProfile.balanced.reducesCoverage)
    }

    func testExclusionsAreCountedNeverSilent() {
        let input = observations([
            "STRIPE=" + "sk" + "_test_RSFAKE0123456789abcdef",
            "API_TOKEN=team-placeholder-token",
            "AKIAIOSFODNN7EXAMPLE",  // native confidence 0.6: below the profile's 65% review threshold
        ])
        var profile = team
        profile.reviewThreshold = 65
        let (detections, report) = ProfiledSecretDetector(profile: profile).detect(in: input)
        XCTAssertEqual(report.hiddenByDisabledRules, 1)
        XCTAssertEqual(report.hiddenByPlaceholders, 1)
        XCTAssertEqual(report.hiddenByThreshold, 1)
        XCTAssertEqual(report.hiddenTotal, 3)
        XCTAssertEqual(detections.count, 0)
        XCTAssertEqual(profile.coverageReductions.count, 3, "Threshold, disabled rule, and placeholders each need confirmation")
    }

    // MARK: - Library

    @MainActor
    func testLibrarySavesSelectsPersistsAndSkipsInvalidStoredProfiles() throws {
        let store = MemoryProfileStore()
        let library = DetectionProfileLibrary(store: store)
        XCTAssertEqual(library.selected, .balanced)
        try library.save(team)
        library.select(team)

        var stored = store.savedProfileDocuments
        stored.append("{\"format\":\"redscreen-detection-profile\",\"version\":1}")
        store.savedProfileDocuments = stored
        let reloaded = DetectionProfileLibrary(store: store)
        XCTAssertEqual(reloaded.userProfiles, [team])
        XCTAssertEqual(reloaded.selected, team)
        XCTAssertEqual(reloaded.skippedStoredProfiles, 1)

        XCTAssertThrowsError(try reloaded.save(DetectionProfile(name: "team rsfake", likelyThreshold: 70, reviewThreshold: 35))) {
            XCTAssertTrue(($0 as? ProfileError)?.issues.first?.contains("already exists") ?? false)
        }
        var edited = team
        edited.likelyThreshold = 60
        try reloaded.save(edited, replacing: team.name)
        XCTAssertEqual(reloaded.selected.likelyThreshold, 60, "Editing the selected profile updates the selection")
        reloaded.delete(edited)
        XCTAssertEqual(reloaded.selected, .balanced)
        XCTAssertEqual(store.savedProfileDocuments, [])

        let exported = try reloaded.exportProfile(team)
        XCTAssertEqual(try reloaded.importProfile(from: exported), team)
    }
}

private final class MemoryProfileStore: DetectionProfileStore {
    var savedProfileDocuments: [String] = []
    var selectedProfileName: String?
}

/// Re-evaluating the open document when the profile changes.
@MainActor
final class DetectionProfileReevaluationTests: XCTestCase {
    private struct Lines: TextRecognizer {
        let lines: [String]
        func recognizeText(in pixels: DecodedPixels, dimensions: PixelDimensions) async throws -> [OCRObservation] {
            try lines.enumerated().map { index, line in
                try OCRObservation(text: line, boundingBox: NormalizedRect(x: 0.05, y: 0.1 + Double(index) * 0.2, width: 0.9, height: 0.15),
                                   boundingBoxOrigin: .topLeft, confidence: Confidence(0.95))
            }
        }
    }

    private struct Solid: ScreenCaptureService {
        func capture(_ target: CaptureTarget) async throws -> ImportedImage {
            let context = try XCTUnwrap(CGContext(data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                                                  space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
            return try CapturedImageNormalizer.normalize(XCTUnwrap(context.makeImage()), treatsTransparentAsProtected: false)
        }
    }

    func testChangingTheProfileReevaluatesDeterministicallyAndKeepsManualRectangles() async throws {
        let controller = ScreenshotImportController(
            lifecycle: SecureImageSessionLifecycle(), importer: ImageIOImageImporter(), screenCapturer: Solid(),
            textRecognizer: Lines(lines: ["DATABASE_PASSWORD=RSFAKE-pg-7d1c9a42", "deploy rsteam_RSFAKE0a1b2c3d4e5f6a7b8c9", "AKIAIOSFODNN7EXAMPLE"]),
            secretDetector: ProfiledSecretDetector(profile: .balanced),
            candidateComposer: GeometricCandidateComposer()
        )
        await controller.captureScreenshot(.display(id: 1))?.value
        await controller.currentRecognition?.value
        await controller.currentDetection?.value
        let manualRect = try ImageRect(x: 10, y: 150, width: 60, height: 20)
        let manualID = try XCTUnwrap(controller.addManualRedaction(manualRect))
        let balancedRules = controller.activeDocument!.candidates.filter { !$0.isManual }.compactMap { $0.evidence.first?.ruleID.rawValue }
        XCTAssertFalse(balancedRules.contains("custom.team-token"))
        XCTAssertEqual(controller.profileReport?.profileName, "Balanced")

        let team = DetectionProfile(
            name: "Team", likelyThreshold: 70, reviewThreshold: 65, disabledRules: ["assignment.env"],
            customRules: [CustomDetectionRule(id: "custom.team-token", kind: .token, prefix: "rsteam_",
                                              minimumLength: 20, maximumLength: 40, confidence: 90)]
        )
        var summaries: [[String]] = []
        for _ in 0..<2 {
            await controller.applySecretDetector(ProfiledSecretDetector(profile: team))?.value
            let candidates = try XCTUnwrap(controller.activeDocument?.candidates)
            summaries.append(candidates.map { "\($0.isManual ? "manual" : $0.evidence.first!.ruleID.rawValue) \($0.disposition) \($0.regions.map(\.rect))" })
            let manual = try XCTUnwrap(candidates.first { $0.id == manualID }, "The manual rectangle survives")
            XCTAssertEqual(manual.regions.first?.rect, manualRect)
        }
        XCTAssertEqual(summaries[0], summaries[1], "Re-evaluation is deterministic")
        let rules = summaries[0].map { String($0.split(separator: " ")[0]) }
        XCTAssertTrue(rules.contains("custom.team-token"))
        XCTAssertFalse(rules.contains("assignment.env"))
        XCTAssertEqual(controller.profileReport?.profileName, "Team")
        XCTAssertEqual(controller.profileReport?.hiddenByDisabledRules, 1)
        XCTAssertGreaterThanOrEqual(controller.profileReport?.hiddenByThreshold ?? 0, 1)
        XCTAssertFalse(controller.canUndoReview, "Review history restarts with the new findings")

        // Back to Balanced restores the native findings, still with the manual rectangle.
        await controller.applySecretDetector(ProfiledSecretDetector(profile: .balanced))?.value
        let restored = controller.activeDocument!.candidates.filter { !$0.isManual }.compactMap { $0.evidence.first?.ruleID.rawValue }
        XCTAssertEqual(restored, balancedRules)
        XCTAssertTrue(controller.activeDocument!.candidates.contains { $0.id == manualID })
    }
}
