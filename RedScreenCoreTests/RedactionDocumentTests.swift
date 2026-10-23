import Foundation
import XCTest

@testable import RedScreenCore

final class RedactionDocumentTests: XCTestCase {
    func testGeneratedCandidateTransitionsPreserveStableIdentityAndProvenance() throws {
        let fixture = try makeFixture(secret: "api-key-super-secret")
        let included = try fixture.candidate.settingDisposition(.included)
        let excluded = try included.settingDisposition(.excluded)

        XCTAssertEqual(included.id, fixture.candidate.id)
        XCTAssertEqual(excluded.id, fixture.candidate.id)
        XCTAssertEqual(excluded.region, fixture.candidate.region)
        XCTAssertEqual(excluded.evidence, fixture.candidate.evidence)
        XCTAssertEqual(excluded.disposition, .excluded)
        XCTAssertEqual(excluded.evidence?.observationIDs, [fixture.observation.id])
        XCTAssertEqual(excluded.evidence?.ruleID, fixture.ruleID)
    }

    func testDocumentDispositionUpdateIsImmutableAndRecordsNonSensitiveEdit() throws {
        let fixture = try makeFixture(secret: "password=do-not-log")
        let original = try fixture.document.replacingCandidates([fixture.candidate])

        let updated = try original.settingDisposition(.included, for: fixture.candidate.id)

        XCTAssertEqual(original.candidates.first?.disposition, .pending)
        XCTAssertTrue(original.userEdits.isEmpty)
        XCTAssertEqual(updated.candidates.first?.disposition, .included)
        XCTAssertEqual(updated.userEdits.count, 1)
        XCTAssertEqual(updated.userEdits.first?.candidateID, fixture.candidate.id)
        XCTAssertEqual(updated.sourceIdentity, original.sourceIdentity)
    }

    func testManualAndGeneratedRegionsShareCandidateModel() throws {
        let fixture = try makeFixture(secret: "token")
        let generatedDocument = try fixture.document.replacingCandidates([fixture.candidate])
        let manualRegion = RedactionRegion(
            rect: try ImageRect(x: 5, y: 6, width: 20, height: 10)
        )

        let updated = try generatedDocument.addingManualRegion(manualRegion)

        XCTAssertEqual(updated.candidates.count, 2)
        XCTAssertEqual(updated.candidates.last?.region, manualRegion)
        XCTAssertEqual(updated.candidates.last?.disposition, .manual)
        XCTAssertNil(updated.candidates.last?.evidence)
        XCTAssertEqual(updated.userEdits.last?.disposition, .manual)
    }

    func testManualCandidateCannotTransitionAndGeneratedCandidateCannotBecomeManual() throws {
        let region = RedactionRegion(rect: try ImageRect(x: 1, y: 1, width: 2, height: 2))
        let manual = RedactionCandidate.manual(region: region)
        let fixture = try makeFixture(secret: "secret")

        XCTAssertThrowsError(try manual.settingDisposition(.excluded)) {
            XCTAssertEqual($0 as? DomainModelError, .invalidCandidateTransition)
        }
        XCTAssertThrowsError(try fixture.candidate.settingDisposition(.manual)) {
            XCTAssertEqual($0 as? DomainModelError, .invalidCandidateTransition)
        }
    }

    func testDocumentRejectsUnknownEvidenceAndOutOfBoundsRegions() throws {
        let fixture = try makeFixture(secret: "secret")
        let noObservations = try RedactionDocument(
            sourceIdentity: SourceImageIdentity(),
            pixelDimensions: fixture.document.pixelDimensions
        )

        XCTAssertThrowsError(try noObservations.replacingCandidates([fixture.candidate])) {
            XCTAssertEqual($0 as? DomainModelError, .unknownObservation)
        }

        let outOfBounds = RedactionRegion(
            rect: try ImageRect(x: 99, y: 49, width: 2, height: 2)
        )
        let manual = RedactionCandidate.manual(region: outOfBounds)
        XCTAssertThrowsError(try fixture.document.replacingCandidates([manual])) {
            XCTAssertEqual($0 as? DomainModelError, .regionOutOfBounds)
        }
    }

    func testInvalidConfidenceRuleAndEvidenceAreRejected() throws {
        XCTAssertThrowsError(try Confidence(.nan)) {
            XCTAssertEqual($0 as? DomainModelError, .confidenceOutOfBounds)
        }
        XCTAssertThrowsError(try Confidence(1.01)) {
            XCTAssertEqual($0 as? DomainModelError, .confidenceOutOfBounds)
        }
        XCTAssertThrowsError(try DetectorRuleID("  ")) {
            XCTAssertEqual($0 as? DomainModelError, .emptyRuleIdentifier)
        }
        XCTAssertThrowsError(try DetectionEvidence(
            ruleID: DetectorRuleID("api-key"),
            observationIDs: [],
            confidence: Confidence(1)
        )) {
            XCTAssertEqual($0 as? DomainModelError, .emptyEvidence)
        }
    }

    func testSensitiveDebugDescriptionsAlwaysRedactPayloadsAndLocations() throws {
        let secret = "ghp_sample_secret_that_must_not_appear"
        let fixture = try makeFixture(secret: secret)
        let image = ScreenshotImage(data: Data(secret.utf8))
        let decoded = DecodedPixels(bytes: Data(secret.utf8))
        let imported = ImportedImage(
            sourceIdentity: fixture.document.sourceIdentity,
            pixelDimensions: fixture.document.pixelDimensions,
            image: image
        )
        let destination = ExportDestination(
            url: URL(fileURLWithPath: "/Users/person/Secret Project/output.png")
        )
        let descriptions = [
            String(describing: fixture.observation),
            String(reflecting: fixture.observation),
            String(describing: fixture.document),
            String(reflecting: fixture.document),
            String(describing: image),
            String(reflecting: decoded),
            String(reflecting: imported),
            String(reflecting: destination)
        ].joined(separator: "\n")

        XCTAssertFalse(descriptions.contains(secret))
        XCTAssertFalse(descriptions.contains("Secret Project"))
        XCTAssertTrue(descriptions.contains("<redacted>"))
    }

    func testSensitiveRuntimePayloadsAreNotCodable() throws {
        XCTAssertFalse(ScreenshotImage.self is any Codable.Type)
        XCTAssertFalse(DecodedPixels.self is any Codable.Type)
        XCTAssertFalse(OCRObservation.self is any Codable.Type)
        XCTAssertFalse(RedactionDocument.self is any Codable.Type)
        XCTAssertFalse(ImportedImage.self is any Codable.Type)
        XCTAssertTrue(SourceImageIdentity.self is any Codable.Type)
        XCTAssertTrue(DetectorRuleID.self is any Codable.Type)
    }

    func testCoreModelsSatisfySendableContracts() {
        requireSendable(PixelDimensions.self)
        requireSendable(NormalizedRect.self)
        requireSendable(ImageRect.self)
        requireSendable(OCRObservation.self)
        requireSendable(RedactionCandidate.self)
        requireSendable(RedactionDocument.self)
        requireSendable(ScreenshotImage.self)
    }

    private func makeFixture(secret: String) throws -> (
        document: RedactionDocument,
        observation: OCRObservation,
        candidate: RedactionCandidate,
        ruleID: DetectorRuleID
    ) {
        let dimensions = try PixelDimensions(width: 100, height: 50)
        let observation = OCRObservation(
            text: secret,
            boundingBox: try NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.2),
            boundingBoxOrigin: .bottomLeft,
            confidence: try Confidence(0.95)
        )
        let ruleID = try DetectorRuleID("developer-api-key")
        let evidence = try DetectionEvidence(
            ruleID: ruleID,
            observationIDs: [observation.id],
            confidence: try Confidence(0.9)
        )
        let candidate = try RedactionCandidate(
            region: RedactionRegion(rect: observation.imageRect(in: dimensions)),
            evidence: evidence
        )
        let document = try RedactionDocument(
            sourceIdentity: SourceImageIdentity(),
            pixelDimensions: dimensions,
            observations: [observation],
            processingState: .textRecognized
        )
        return (document, observation, candidate, ruleID)
    }

    private func requireSendable<T: Sendable>(_: T.Type) {}
}
