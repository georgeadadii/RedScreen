import Foundation
import XCTest

@testable import RedScreenCore

final class SyntheticValuePolicyTests: XCTestCase {
    // MARK: - Canary over the committed corpus

    func testEveryFixtureValueMatchesTheSyntheticValuePolicy() throws {
        let policy = SyntheticValuePolicy(forbiddenIdentities: [NSUserName(), NSFullUserName()])
        let violations = try FixtureLibrary.bundled().fixtures().flatMap {
            policy.violations(in: $0.groundTruth)
        }
        XCTAssertEqual(violations, [], violations.map(\.description).joined(separator: "\n"))
    }

    func testEverySensitiveAndAmbiguousSpanCarriesAReservedMarker() throws {
        for fixture in try FixtureLibrary.bundled().fixtures() {
            for span in fixture.groundTruth.spans where span.expectation != .benign {
                let value = try XCTUnwrap(fixture.groundTruth.text(of: span))
                XCTAssertTrue(
                    SyntheticValuePolicy.containsMarker(value),
                    "\(fixture.id) span \(span.id) is not marked synthetic"
                )
            }
        }
    }

    // MARK: - Policy self-tests

    func testPolicyRejectsRealisticValuesWithoutMarkers() {
        let policy = SyntheticValuePolicy()
        // Assembled at runtime so this source file never contains a credential-shaped literal.
        let alphanumerics = "Ab3dE5gH7jK9mN1pQ2rS4tU6vW8xY0zA1bC2"
        let cases: [(String, SyntheticValuePolicy.Rule)] = [
            ("AKIA" + "ZQ7XK2LM4NP8RT6V", .credentialShapeWithoutMarker),
            ("token=" + "gh" + "p_" + alphanumerics, .credentialShapeWithoutMarker),
            ("Authorization: Bearer " + alphanumerics, .credentialShapeWithoutMarker),
            ("postgres://admin:" + "Tr0ub4dor" + "@db.internal.test/app", .credentialShapeWithoutMarker),
            ("eyJ" + "hbGciOiJub25lIn0" + ".eyJzdWIiOiIxMjMifQ", .credentialShapeWithoutMarker),
            ("contact " + "jane.doe" + "@" + "gmail.com", .unreservedEmailDomain),
            ("curl https://" + "api.github.com" + "/user", .unreservedHost),
            ("connect to " + "10.20.30.40", .unreservedIPv4Address),
            ("cat " + "/Users/" + "someone/.env", .userHomePath),
        ]
        for (text, rule) in cases {
            XCTAssertTrue(policy.textViolations(in: text).contains(rule), "Expected \(rule)")
        }
    }

    func testPolicyAcceptsMarkedAndReservedValues() {
        let policy = SyntheticValuePolicy()
        let accepted = [
            "export AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE",
            "Authorization: Bearer RSFAKE-tok-9Qw2Ex7Rt5",
            "Authorization: Bearer $DEPLOY_TOKEN",
            "mysql://svc:RSFAKE-my-31@mysql.internal.test/app",
            "mailer@example.com and support@example.org",
            "http://127.0.0.1:5173/ and http://localhost:8080",
            "Last used from 203.0.113.10 and 198.51.100.7",
            "demo % ssh-keygen -lf ~/.ssh/id_ed25519.pub",
        ]
        for text in accepted {
            XCTAssertEqual(policy.textViolations(in: text), [], text)
        }
    }

    func testPolicyRejectsUnmarkedSensitiveSpansAndPrivateKeysAndLocalIdentities() throws {
        let original = try FixtureLibrary.bundled().fixture(id: "private-key-block-light-1x")
            .groundTruth
        let unmarkedBoxes = original.textBoxes.map { box in
            FixtureTextBox(
                id: box.id,
                text: box.text.replacingOccurrences(of: "RSFAKE", with: "MIIEow"),
                rect: box.rect
            )
        }
        let tampered = FixtureGroundTruth(
            schemaVersion: original.schemaVersion,
            id: original.id,
            scenario: original.scenario,
            syntheticTestData: false,
            category: original.category,
            theme: original.theme,
            fontStyle: original.fontStyle,
            scale: original.scale,
            difficulties: original.difficulties,
            pixelWidth: original.pixelWidth,
            pixelHeight: original.pixelHeight,
            coordinateSpace: original.coordinateSpace,
            textBoxes: unmarkedBoxes,
            spans: original.spans
        )

        let rules = Set(SyntheticValuePolicy(forbiddenIdentities: ["synthetic-keys"])
            .violations(in: tampered).map(\.rule))
        XCTAssertEqual(rules, [
            .missingSyntheticFlag,
            .sensitiveValueWithoutMarker,
            .privateKeyWithoutSyntheticBody,
            .localAccountIdentity,
        ])
    }

    func testViolationDescriptionsDoNotEchoText() {
        let violation = SyntheticValuePolicy.Violation(
            fixtureID: "fixture-1x", textBoxID: "t03", spanID: "span", rule: .unreservedHost
        )
        XCTAssertEqual(
            violation.description, "unreservedHost: fixture fixture-1x, text box t03, span span"
        )
    }

    // MARK: - Generator isolation

    func testFixtureGeneratorCannotReadTheDeveloperEnvironment() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let generatorSources = [
            "Tools/FixtureGenerator/main.swift",
            "RedScreenCoreTests/FixtureSupport/FixtureSchema.swift",
            "RedScreenCoreTests/FixtureSupport/FixtureScenarios.swift",
            "RedScreenCoreTests/FixtureSupport/FixtureRenderer.swift",
        ]
        let forbiddenAPIs = [
            "ProcessInfo", "getenv", ".environment", "NSHomeDirectory", "homeDirectory",
            "NSUserName", "NSFullUserName", "contentsOf", "contentsOfDirectory", "enumerator(",
            "URLSession", "URLRequest", "Process(", "Bundle.", "UserDefaults", "NSPasteboard",
            "CGWindowList", "CGDisplayCreateImage", "SCScreenshotManager",
        ]
        for path in generatorSources {
            let source = try String(
                contentsOf: repository.appendingPathComponent(path), encoding: .utf8
            )
            for api in forbiddenAPIs {
                XCTAssertFalse(source.contains(api), "\(path) must not use \(api)")
            }
        }

        let profile = try String(
            contentsOf: repository.appendingPathComponent("Tools/FixtureGenerator/generator.sb"),
            encoding: .utf8
        )
        XCTAssertTrue(profile.contains("(deny network*)"))
        XCTAssertTrue(profile.contains("(deny file-read-data (subpath (param \"HOME_DIR\")))"))
        XCTAssertTrue(profile.contains("(deny file-write*)"))
        XCTAssertTrue(profile.contains("(deny process-exec)"))

        let makefile = try String(
            contentsOf: repository.appendingPathComponent("Makefile"), encoding: .utf8
        )
        XCTAssertTrue(makefile.contains(
            "/usr/bin/env -i /usr/bin/sandbox-exec -f Tools/FixtureGenerator/generator.sb"
        ))
    }
}
