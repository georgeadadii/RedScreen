import Foundation

public enum DomainModelError: Error, Equatable, Sendable {
    case confidenceOutOfBounds
    case emptyRuleIdentifier
    case emptyEvidence
    case duplicateIdentifier
    case unknownObservation
    case invalidCandidateDisposition
    case invalidCandidateTransition
    case candidateNotFound
    case regionOutOfBounds
}

/// Non-sensitive stable identity for an imported source. It never contains a filename or URL.
public struct SourceImageIdentity: Equatable, Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

/// A finite OCR or detector confidence in the closed range `0...1`.
public struct Confidence: Equatable, Hashable, Sendable {
    public let value: Double

    public init(_ value: Double) throws {
        guard value.isFinite, (0...1).contains(value) else {
            throw DomainModelError.confidenceOutOfBounds
        }
        self.value = value
    }
}

/// Sensitive OCR text plus its source bounding box.
///
/// This type intentionally does not conform to `Codable`. Its descriptions always redact text.
public struct OCRObservation: Identifiable, Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible {
    public let id: UUID
    public let text: String
    public let boundingBox: NormalizedRect
    public let boundingBoxOrigin: NormalizedCoordinateOrigin
    public let confidence: Confidence

    public init(
        id: UUID = UUID(),
        text: String,
        boundingBox: NormalizedRect,
        boundingBoxOrigin: NormalizedCoordinateOrigin,
        confidence: Confidence
    ) {
        self.id = id
        self.text = text
        self.boundingBox = boundingBox
        self.boundingBoxOrigin = boundingBoxOrigin
        self.confidence = confidence
    }

    public func imageRect(in dimensions: PixelDimensions) throws -> ImageRect {
        try ImageRect(
            normalized: boundingBox,
            dimensions: dimensions,
            sourceOrigin: boundingBoxOrigin
        )
    }

    public var description: String { "OCRObservation(id: \(id), text: <redacted>)" }
    public var debugDescription: String { description }
}

/// Stable, non-sensitive identifier for a detector rule. Configuration may safely persist it.
public struct DetectorRuleID: Equatable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DomainModelError.emptyRuleIdentifier
        }
        self.rawValue = rawValue
    }
}

/// Provenance for a detection, referencing OCR identities rather than copying matched text.
public struct DetectionEvidence: Equatable, Sendable {
    public let ruleID: DetectorRuleID
    public let observationIDs: [OCRObservation.ID]
    public let confidence: Confidence

    public init(
        ruleID: DetectorRuleID,
        observationIDs: [OCRObservation.ID],
        confidence: Confidence
    ) throws {
        guard !observationIDs.isEmpty else { throw DomainModelError.emptyEvidence }
        guard Set(observationIDs).count == observationIDs.count else {
            throw DomainModelError.duplicateIdentifier
        }
        self.ruleID = ruleID
        self.observationIDs = observationIDs
        self.confidence = confidence
    }
}

/// Detector output before one or more observations are composed into a review candidate.
public struct SecretDetection: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let evidence: DetectionEvidence

    public init(id: UUID = UUID(), evidence: DetectionEvidence) {
        self.id = id
        self.evidence = evidence
    }
}

/// The rectangle consumed by review and rendering for both generated and manual redactions.
public struct RedactionRegion: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let rect: ImageRect

    public init(id: UUID = UUID(), rect: ImageRect) {
        self.id = id
        self.rect = rect
    }
}

public enum RedactionDisposition: Equatable, Sendable {
    case pending
    case included
    case excluded
    case manual
}

/// One reviewable redaction. Generated candidates retain evidence; manual candidates do not.
public struct RedactionCandidate: Identifiable, Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible {
    public let id: UUID
    public let region: RedactionRegion
    public let evidence: DetectionEvidence?
    public let disposition: RedactionDisposition

    public init(
        id: UUID = UUID(),
        region: RedactionRegion,
        evidence: DetectionEvidence,
        disposition: RedactionDisposition = .pending
    ) throws {
        guard disposition != .manual else { throw DomainModelError.invalidCandidateDisposition }
        self.id = id
        self.region = region
        self.evidence = evidence
        self.disposition = disposition
    }

    public static func manual(id: UUID = UUID(), region: RedactionRegion) -> RedactionCandidate {
        RedactionCandidate(id: id, region: region)
    }

    private init(id: UUID, region: RedactionRegion) {
        self.id = id
        self.region = region
        evidence = nil
        disposition = .manual
    }

    public func settingDisposition(_ disposition: RedactionDisposition) throws -> RedactionCandidate {
        guard evidence != nil, disposition != .manual else {
            throw DomainModelError.invalidCandidateTransition
        }
        return try RedactionCandidate(
            id: id,
            region: region,
            evidence: evidence!,
            disposition: disposition
        )
    }

    public var description: String {
        "RedactionCandidate(id: \(id), disposition: \(disposition))"
    }
    public var debugDescription: String { description }
}

/// Non-sensitive edit history. It references candidate identity and state but never OCR text.
public struct RedactionEdit: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let candidateID: RedactionCandidate.ID
    public let disposition: RedactionDisposition

    public init(
        id: UUID = UUID(),
        candidateID: RedactionCandidate.ID,
        disposition: RedactionDisposition
    ) {
        self.id = id
        self.candidateID = candidateID
        self.disposition = disposition
    }
}

public enum ProcessingFailureCode: Equatable, Sendable {
    case importFailed
    case recognitionFailed
    case detectionFailed
    case renderingFailed
    case exportFailed
}

public enum RedactionProcessingState: Equatable, Sendable {
    case imported
    case recognizingText
    case textRecognized
    case detectingSecrets
    case readyForReview
    case rendering
    case readyToExport
    case failed(ProcessingFailureCode)
}

/// Immutable sensitive runtime snapshot for one source image.
///
/// It owns no image buffers. `SecureImageSession` remains the sole owner of source, decoded,
/// preview, and clipboard image references. This type intentionally is not `Codable`.
public struct RedactionDocument: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible {
    public let sourceIdentity: SourceImageIdentity
    public let pixelDimensions: PixelDimensions
    public let observations: [OCRObservation]
    public let candidates: [RedactionCandidate]
    public let userEdits: [RedactionEdit]
    public let processingState: RedactionProcessingState

    public init(
        sourceIdentity: SourceImageIdentity,
        pixelDimensions: PixelDimensions,
        observations: [OCRObservation] = [],
        candidates: [RedactionCandidate] = [],
        userEdits: [RedactionEdit] = [],
        processingState: RedactionProcessingState = .imported
    ) throws {
        guard Set(observations.map(\.id)).count == observations.count,
              Set(candidates.map(\.id)).count == candidates.count,
              Set(candidates.map(\.region.id)).count == candidates.count,
              Set(userEdits.map(\.id)).count == userEdits.count else {
            throw DomainModelError.duplicateIdentifier
        }

        let observationIDs = Set(observations.map(\.id))
        for candidate in candidates {
            guard candidate.region.rect.isContained(in: pixelDimensions) else {
                throw DomainModelError.regionOutOfBounds
            }
            if let evidence = candidate.evidence,
               !Set(evidence.observationIDs).isSubset(of: observationIDs) {
                throw DomainModelError.unknownObservation
            }
        }

        let candidateIDs = Set(candidates.map(\.id))
        guard userEdits.allSatisfy({ candidateIDs.contains($0.candidateID) }) else {
            throw DomainModelError.candidateNotFound
        }

        self.sourceIdentity = sourceIdentity
        self.pixelDimensions = pixelDimensions
        self.observations = observations
        self.candidates = candidates
        self.userEdits = userEdits
        self.processingState = processingState
    }

    public func replacingObservations(
        _ observations: [OCRObservation],
        processingState: RedactionProcessingState = .textRecognized
    ) throws -> RedactionDocument {
        try RedactionDocument(
            sourceIdentity: sourceIdentity,
            pixelDimensions: pixelDimensions,
            observations: observations,
            candidates: [],
            userEdits: [],
            processingState: processingState
        )
    }

    public func replacingCandidates(
        _ candidates: [RedactionCandidate],
        processingState: RedactionProcessingState = .readyForReview
    ) throws -> RedactionDocument {
        try RedactionDocument(
            sourceIdentity: sourceIdentity,
            pixelDimensions: pixelDimensions,
            observations: observations,
            candidates: candidates,
            userEdits: [],
            processingState: processingState
        )
    }

    public func settingDisposition(
        _ disposition: RedactionDisposition,
        for candidateID: RedactionCandidate.ID,
        editID: UUID = UUID()
    ) throws -> RedactionDocument {
        guard let index = candidates.firstIndex(where: { $0.id == candidateID }) else {
            throw DomainModelError.candidateNotFound
        }
        var updatedCandidates = candidates
        updatedCandidates[index] = try updatedCandidates[index].settingDisposition(disposition)
        let edit = RedactionEdit(
            id: editID,
            candidateID: candidateID,
            disposition: disposition
        )
        return try RedactionDocument(
            sourceIdentity: sourceIdentity,
            pixelDimensions: pixelDimensions,
            observations: observations,
            candidates: updatedCandidates,
            userEdits: userEdits + [edit],
            processingState: processingState
        )
    }

    public func addingManualRegion(
        _ region: RedactionRegion,
        candidateID: UUID = UUID(),
        editID: UUID = UUID()
    ) throws -> RedactionDocument {
        let candidate = RedactionCandidate.manual(id: candidateID, region: region)
        let edit = RedactionEdit(
            id: editID,
            candidateID: candidateID,
            disposition: .manual
        )
        return try RedactionDocument(
            sourceIdentity: sourceIdentity,
            pixelDimensions: pixelDimensions,
            observations: observations,
            candidates: candidates + [candidate],
            userEdits: userEdits + [edit],
            processingState: processingState
        )
    }

    public var description: String {
        "RedactionDocument(source: \(sourceIdentity.rawValue), observations: \(observations.count), candidates: \(candidates.count))"
    }
    public var debugDescription: String { description }
}
