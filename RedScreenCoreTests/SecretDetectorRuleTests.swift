import Foundation
import XCTest

@testable import RedScreenCore

/// Table-driven rule tests for `ContextualSecretDetector` (issue #7).
///
/// All values are synthetic and marked `RSFAKE`/`rsfake`, or are AWS's published documentation
/// examples. Shapes that real secret scanners match are assembled at runtime.
final class SecretDetectorRuleTests: XCTestCase {
    private let detector = ContextualSecretDetector()

    // MARK: - Positive cases: one table per family

    struct Case {
        let lines: [String]
        let value: String
        let family: SecretFamily?
        let assessment: DetectionAssessment
        let note: String

        init(
            _ lines: [String],
            _ value: String,
            _ family: SecretFamily? = nil,
            _ assessment: DetectionAssessment = .likely,
            _ note: String = ""
        ) {
            self.lines = lines
            self.value = value
            self.family = family
            self.assessment = assessment
            self.note = note
        }

        init(
            _ line: String,
            _ value: String,
            _ family: SecretFamily? = nil,
            _ assessment: DetectionAssessment = .likely,
            _ note: String = ""
        ) {
            self.init([line], value, family, assessment, note)
        }
    }

    func testEnvAssignmentFamily() {
        check([
            Case("DATABASE_PASSWORD=RSFAKE-pg-7d1c9a42", "RSFAKE-pg-7d1c9a42", .envAssignment),
            Case("API_KEY = RSFAKE-key-6b2d91", "RSFAKE-key-6b2d91", .envAssignment,
                 .likely, "spaces around separator"),
            Case("export AWS_SECRET_ACCESS_KEY=\"wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY\"",
                 "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", .envAssignment, .likely,
                 "quoted, quotes excluded"),
            Case("PASSW0RD=RSFAKE-ocr-pw-42", "RSFAKE-ocr-pw-42", .envAssignment, .likely,
                 "OCR 0/O confusion in key"),
            Case("SIGNING_KEY=RSFAKEq9W3e7R1t5Y8u2I6", "RSFAKEq9W3e7R1t5Y8u2I6"),
            Case("SESSION_SALT=RSFAKEa1b2c3", "RSFAKEa1b2c3", .highEntropyContextual, .needsReview,
                 "weak context word"),
            Case("TRACE_TOKEN=rsfake-ambig-01", "rsfake-ambig-01", nil, .needsReview,
                 "generic token keyword, modest value"),
        ])
    }

    func testCredentialKeywordFamily() {
        check([
            Case("  \"apiKey\": \"RSFAKE-api-3e7b91c4d2\",", "RSFAKE-api-3e7b91c4d2", .credentialKeyword),
            Case("      db_password:   RSFAKE-yaml-pw-91", "RSFAKE-yaml-pw-91", .credentialKeyword),
            Case("client_secret = 'RSFAKE-cs-81fa22b0e9'", "RSFAKE-cs-81fa22b0e9", .credentialKeyword),
            Case("OK - the new password is: RSFAKE-n3w.P@ss_77 (temporary).", "RSFAKE-n3w.P@ss_77",
                 .credentialKeyword, .likely, "prose with connector"),
            Case("  \"passwordHint\": \"RSFAKE-hint-blue42\",", "RSFAKE-hint-blue42", nil,
                 .needsReview, "hint about a password"),
            Case("I reset it to 'RSFAKE-Temp!Pass#2026' but login fails.", "RSFAKE-Temp!Pass#2026",
                 .credentialKeyword, .needsReview, "quoted value in password prose"),
        ])
    }

    func testBearerTokenFamily() {
        check([
            Case("Authorization: Bearer RSFAKE-tok-9Qw2Ex7Rt5", "RSFAKE-tok-9Qw2Ex7Rt5", .bearerToken),
            Case("curl -H \"Authorization: Bearer RSFAKE.eyJhbGciOiJIUzI1NiJ9.RSFAKEsig\" \\",
                 "RSFAKE.eyJhbGciOiJIUzI1NiJ9.RSFAKEsig", .bearerToken),
            Case("authorization:   bearer   RSFAKEbearer0123456789", "RSFAKEbearer0123456789",
                 .bearerToken, .likely, "case and spacing"),
            Case("Retrying with Bearer RSFAKE-tr...", "RSFAKE-tr...", .bearerToken, .needsReview,
                 "truncated"),
        ])
    }

    func testPrivateKeyFamily() {
        let block = [
            "-----BEGIN RSA PRIVATE KEY-----",
            "RSFAKEsyntheticKeyBodyLine0001NotARealKeyAAAA",
            "RSFAKEsyntheticKeyBodyLine0002NotARealKeyBBBB",
            "-----END RSA PRIVATE KEY-----",
        ]
        let detections = detector.detect(in: observations(block))
        XCTAssertEqual(detections.count, 1)
        let detection = detections[0]
        XCTAssertEqual(detection.family, .privateKey)
        XCTAssertEqual(detection.severity, .critical)
        XCTAssertEqual(detection.assessment, .likely)
        XCTAssertEqual(detection.spans.count, 4, "Header, body, and footer are all covered")

        // OCR renders dash runs as em-dashes; normalization still finds the armor.
        let ocrBlock = ["-----BEGIN OPENSSH PRIVATE KEY-\u{2014}\u{2014}-", "RSFAKEb3BlbnNzaC1rZXk", "-----END OPENSSH PRIVATE KEY-----"]
        XCTAssertEqual(detector.detect(in: observations(ocrBlock)).first?.family, .privateKey)

        let encrypted = ["-----BEGIN ENCRYPTED PRIVATE KEY-----", "RSFAKEsyntheticEncrypted0001", "-----END ENCRYPTED PRIVATE KEY-----"]
        XCTAssertEqual(detector.detect(in: observations(encrypted)).first?.assessment, .needsReview)

        let certificate = ["-----BEGIN CERTIFICATE-----", "MIIBsyntheticPublicCertificateBody", "-----END CERTIFICATE-----"]
        XCTAssertEqual(detector.detect(in: observations(certificate)), [])
    }

    func testConnectionStringFamily() {
        check([
            Case("DATABASE_URL=postgres://app:RSFAKE-db-pw@db.internal.test:5432/app", "RSFAKE-db-pw",
                 .connectionString),
            Case("REDIS_URL='redis://:RSFAKE-redis-77@cache.internal.test:6379/0'", "RSFAKE-redis-77",
                 .connectionString, .likely, "empty username"),
            Case("MONGO_URL: mongodb://rsfake_reporter@mongo.internal.test/db", "rsfake_reporter",
                 .connectionString, .needsReview, "username without password"),
        ])
    }

    func testWrappedConnectionStringIsJoinedAcrossLines() throws {
        let lines = [
            "DATABASE_URL=postgres://app_user:RSFAKE-",
            "Pg-9f8e7d@db.internal.test:5432/orders",
        ]
        let input = observations(lines)
        let detections = detector.detect(in: input)

        let detection = try XCTUnwrap(detections.first { $0.family == .connectionString })
        XCTAssertEqual(detection.assessment, .likely)
        XCTAssertEqual(detection.spans.map { text(of: $0, in: input) }, ["RSFAKE-", "Pg-9f8e7d"])
    }

    func testProviderKeyShapeFamily() {
        let stripeLive = "sk" + "_live_" + "RSFAKE" + String(repeating: "0", count: 20)
        check([
            Case("demo % export GITHUB_TOKEN=ghp_RSFAKE0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c",
                 "ghp_RSFAKE0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c", .providerKeyShape),
            Case("ghp_RSFAKE0a1b2c3d4e5f6a7b8c9d@e1f2a3b4c", "ghp_RSFAKE0a1b2c3d4e5f6a7b8c9d@e1f2a3b4c",
                 .providerKeyShape, .likely, "OCR read 0 as @"),
            Case("slack: xoxb-RSFAKEonly-tokentext", "xoxb-RSFAKEonly-tokentext", .providerKeyShape),
            Case("STRIPE=\(stripeLive)", stripeLive, .providerKeyShape),
            Case("export AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE", "AKIAIOSFODNN7EXAMPLE",
                 .providerKeyShape, .likely, "exported beside its secret"),
            Case("Access key AKIAI44QH8DHBEXAMPLE shown in console", "AKIAI44QH8DHBEXAMPLE",
                 .providerKeyShape, .needsReview, "an access key ID alone is an identifier"),
        ])
    }

    func testHighEntropyContextualFamily() {
        check([
            Case("12:00:12 DEBUG webhook signing secret=7Hq2RSFAKEz9Lp4Wm8Xc3Vb6Nf1Kd5Tg",
                 "7Hq2RSFAKEz9Lp4Wm8Xc3Vb6Nf1Kd5Tg"),
            Case("webhook signing secret 7Hq2RSFAKEz9Lp4Wm8Xc3Vb6Nf1Kd5Tg",
                 "7Hq2RSFAKEz9Lp4Wm8Xc3Vb6Nf1Kd5Tg", .highEntropyContextual, .likely, "no separator"),
            Case("12:00:18 deploy nonce rsfake9c1f2e7a4b8d6c", "rsfake9c1f2e7a4b8d6c",
                 .highEntropyContextual, .needsReview, "weak context"),
            Case("INTERNAL_ID=RSFAKE7f3a9c2e1b5d", "RSFAKE7f3a9c2e1b5d", .highEntropyContextual,
                 .needsReview),
        ])
    }

    func testTwoColumnTableLabels() throws {
        func row(_ label: String, _ value: String) -> [OCRObservation] {
            [observation(label, x: 0.05, y: 0.4, width: 0.25),
             observation(value, x: 0.4, y: 0.4, width: 0.5)]
        }
        let secret = row("Secret access key", "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
        let found = try XCTUnwrap(detector.detect(in: secret).first)
        XCTAssertEqual(found.assessment, .likely)
        XCTAssertEqual(found.spans.first?.observationID, secret[1].id, "Value cell, not the label")

        let masked = row("Staging secret", "svc_test_RSFAKE\u{2022}\u{2022}\u{2022}\u{2022}3c1d")
        XCTAssertEqual(detector.detect(in: masked).first?.assessment, .needsReview)

        XCTAssertEqual(detector.detect(in: row("Publishable", "pk_pub_RSFAKE9a8b7c6d")), [])
        XCTAssertEqual(detector.detect(in: row("Region", "us-west-2")), [])
    }

    // MARK: - Negative cases and regressions

    func testBenignValuesAndCounterexamplesAreNotDetected() {
        let benign = [
            "NODE_ENV=production",
            "PORT=3000",
            "export AWS_REGION=us-east-1",
            "API_BASE_URL=http://localhost:8080/api",
            "READ_REPLICA_URL=postgres://localhost:5432/orders",
            "CACHE_URL: redis://127.0.0.1:6379",
            "git clone ssh://git@code.example.test/team/repo.git",
            "JWT_SECRET=changeme",
            "API_KEY=your-api-key-here",
            "DB_PASS=<password>",
            "password: ${DB_PASSWORD}",
            "token=$GITHUB_TOKEN",
            "Authorization: Bearer <token>",
            "let header = \"Authorization: Bearer \\(token)\"",
            "12:00:22 Authorization: Bearer $DEPLOY_TOKEN",
            "{\"projects\":[],\"request_id\":\"c0ffee00-1234-4abc-8def-000000000001\"}",
            "let requestID = UUID(uuidString: \"123e4567-e89b-12d3-a456-426614174000\")",
            "GIT_SHA=3f869f9c2b7e4d1a0f5e6c8b9a7d3e2f1c0b4a59",
            "let commit = \"d7ff0b2693f9daac91b2338d2eb5dd02568a19a9\"",
            "12:00:01 Run actions/checkout@v4 (ref 63c2d54687ed)",
            "added 214 packages, integrity sha512-Zm9vYmFyYmF6cXV4cXV1eA==",
            "  \"checksum\": \"sha256-9b74c9897bac770ffc029102a200c5de\"",
            "256 SHA256:RSFAKEfingerprintAbCdEf0123456789 dev@workstation (ED25519)",
            "  \"clientId\": \"web-dashboard-client\",",
            "  \"tokenTTL\": 3600,",
            "      PASSWORD_MIN_LENGTH: \"12\"",
            "    ports: [\"8080:8080\"]",
            "  Token: ghp_************************************",
            "  Token scopes: 'repo', 'read:org'",
            "12:00:04 Using registry token ***",
            "let password = try keychain.read(account: user)",
            "// TODO: rotate the token before release",
            "Agent: Please never share your password; use the reset link.",
            "SMTP_USER=mailer@example.com",
            "LOG_LEVEL=debug",
            "FEATURE_FLAGS=search,exports",
        ]
        for line in benign {
            XCTAssertEqual(detector.detect(in: observations([line])), [], line)
        }
    }

    // MARK: - Properties

    func testDetectionIsDeterministic() {
        let input = observations([
            "DATABASE_PASSWORD=RSFAKE-pg-7d1c9a42",
            "Authorization: Bearer RSFAKE-tok-9Qw2Ex7Rt5",
            "SESSION_SALT=RSFAKEa1b2c3",
            "MONGO_URL: mongodb://rsfake_reporter@mongo.internal.test/db",
        ])
        func signature(_ detections: [SecretDetection]) -> [String] {
            detections.map {
                "\($0.evidence.ruleID.rawValue)|\($0.family)|\($0.assessment)|\($0.evidence.confidence.value)|"
                    + $0.spans.map { "\($0.observationID):\($0.utf16Range)" }.joined(separator: ",")
            }
        }
        let first = signature(detector.detect(in: input))
        for _ in 0..<5 {
            XCTAssertEqual(signature(detector.detect(in: input)), first)
        }
        XCTAssertEqual(first.count, 4)
    }

    func testFindingsNeverEchoTextInDescriptions() throws {
        let input = observations(["DATABASE_PASSWORD=RSFAKE-pg-7d1c9a42"])
        let detection = try XCTUnwrap(detector.detect(in: input).first)
        XCTAssertFalse(String(describing: detection).contains("RSFAKE"))
        XCTAssertFalse(String(reflecting: detection).contains("RSFAKE"))
    }

    func testMalformedUnicodeAndRandomInputNeverCrashOrEscapeBounds() {
        var generator = SeededGenerator(seed: 0x5EC12E7)
        let alphabet: [UnicodeScalar] = Array("abcXYZ019=:\"'@/-_ .*\u{2014}\u{201C}".unicodeScalars)
            + [UnicodeScalar(0)!, UnicodeScalar(0x301)!, UnicodeScalar(0x202E)!, UnicodeScalar(0xFFFD)!,
               UnicodeScalar(0x1F511)!, UnicodeScalar(0x200B)!, UnicodeScalar(0xFEFF)!]
        for _ in 0..<300 {
            let lines = (0..<Int.random(in: 1...6, using: &generator)).map { _ in
                var scalars = String.UnicodeScalarView()
                for _ in 0..<Int.random(in: 0...400, using: &generator) {
                    scalars.append(alphabet.randomElement(using: &generator)!)
                }
                if Bool.random(using: &generator) {
                    scalars.append(contentsOf: "password=RSFAKE\u{1F511}x9\u{301}Q".unicodeScalars)
                }
                return String(scalars)
            }
            let input = observations(lines)
            for detection in detector.detect(in: input) {
                for span in detection.spans {
                    let length = input.first { $0.id == span.observationID }!.text.utf16.count
                    XCTAssertGreaterThanOrEqual(span.utf16Range.lowerBound, 0)
                    XCTAssertLessThanOrEqual(span.utf16Range.upperBound, length)
                    XCTAssertFalse(span.utf16Range.isEmpty)
                }
            }
        }
    }

    func testLongAndNumerousInputsAreBounded() {
        let long = String(repeating: "password=RSFAKE-long-value-0001 a:b=c ", count: 6_000)
        let many = (0..<6_000).map { "LINE_\($0)=RSFAKE-pw-\($0)x" }
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            _ = detector.detect(in: observations([long]))
            _ = detector.detect(in: observations(many))
        }
        XCTAssertLessThan(elapsed, .seconds(10), "Detection must stay bounded")

        // Only the first `maximumAnalyzedUTF16PerObservation` units of a line are analysed.
        let limit = SecretDetectionThresholds.standard.maximumAnalyzedUTF16PerObservation
        for detection in detector.detect(in: observations([long])) {
            XCTAssertTrue(detection.spans.allSatisfy { $0.utf16Range.upperBound <= limit })
        }
    }

    func testCancellationIsHonoured() async {
        let input = observations((0..<3_000).map { "DATABASE_PASSWORD=RSFAKE-pw-\($0)abcdef" })
        let detector = ContextualSecretDetector()
        let task = Task { try await detector.detectSecrets(in: input) }
        task.cancel()
        do {
            _ = try await task.value
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    // MARK: - Helpers

    private func check(_ cases: [Case], file: StaticString = #filePath, line: UInt = #line) {
        for testCase in cases {
            let input = observations(testCase.lines)
            let detections = detector.detect(in: input)
            let label = "\(testCase.lines.joined(separator: " / ")) \(testCase.note)"
            guard let detection = detections.first(where: { detection in
                detection.spans.map { text(of: $0, in: input) }.joined() == testCase.value
            }) else {
                XCTFail("No finding covering exactly the value: \(label); got \(detections)",
                        file: file, line: line)
                continue
            }
            XCTAssertEqual(detection.assessment, testCase.assessment, label, file: file, line: line)
            if let family = testCase.family {
                XCTAssertEqual(detection.family, family, label, file: file, line: line)
            }
            XCTAssertEqual(detections.count, 1, "Exactly one finding: \(label)", file: file, line: line)
        }
    }

    private func text(of span: DetectedTextSpan, in observations: [OCRObservation]) -> String {
        let text = observations.first { $0.id == span.observationID }!.text
        let utf16 = Array(text.utf16)
        return String(decoding: utf16[span.utf16Range], as: UTF16.self)
    }

    private func observations(_ lines: [String]) -> [OCRObservation] {
        lines.enumerated().map { index, line in
            observation(line, x: 0.05, y: 0.02 + Double(index) * 0.05, width: 0.9)
        }
    }

    private func observation(_ text: String, x: Double, y: Double, width: Double) -> OCRObservation {
        OCRObservation(
            text: text,
            boundingBox: try! NormalizedRect(x: x, y: min(y, 0.95), width: width, height: 0.04),
            boundingBoxOrigin: .topLeft,
            confidence: try! Confidence(0.9)
        )
    }
}

/// Small deterministic PRNG (SplitMix64) for reproducible fuzzing.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
