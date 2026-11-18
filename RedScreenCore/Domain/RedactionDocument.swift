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
    case spanOutOfBounds
    case unknownDetection
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

/// Location of part of an observation's text, such as one whitespace-delimited word.
///
/// `utf16Range` indexes the owning observation's `text`; the box uses the observation's origin.
/// It carries no text of its own.
public struct OCRTextSegment: Equatable, Sendable {
    public let utf16Range: Range<Int>
    public let boundingBox: NormalizedRect

    public init(utf16Range: Range<Int>, boundingBox: NormalizedRect) {
        self.utf16Range = utf16Range
        self.boundingBox = boundingBox
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
    /// Finer-grained boxes, when the recognizer provides them. Empty means line-level only.
    public let segments: [OCRTextSegment]

    public init(
        id: UUID = UUID(),
        text: String,
        boundingBox: NormalizedRect,
        boundingBoxOrigin: NormalizedCoordinateOrigin,
        confidence: Confidence,
        segments: [OCRTextSegment] = []
    ) {
        self.id = id
        self.text = text
        self.boundingBox = boundingBox
        self.boundingBoxOrigin = boundingBoxOrigin
        self.confidence = confidence
        self.segments = segments
    }

    public func imageRect(in dimensions: PixelDimensions) throws -> ImageRect {
        try ImageRect(
            normalized: boundingBox,
            dimensions: dimensions,
            sourceOrigin: boundingBoxOrigin
        )
    }

    public func imageRect(
        for segment: OCRTextSegment,
        in dimensions: PixelDimensions
    ) throws -> ImageRect {
        try ImageRect(
            normalized: segment.boundingBox,
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
///
/// It locates the sensitive **value** (not its label) by observation identity and UTF-16 range,
/// so no matched text is copied. Wrapped values have one span per observation.
public struct SecretDetection: Identifiable, Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible {
    public let id: UUID
    public let evidence: DetectionEvidence
    public let family: SecretFamily
    public let severity: SecretSeverity
    public let assessment: DetectionAssessment
    public let spans: [DetectedTextSpan]

    public init(
        id: UUID = UUID(),
        evidence: DetectionEvidence,
        family: SecretFamily,
        severity: SecretSeverity,
        assessment: DetectionAssessment,
        spans: [DetectedTextSpan]
    ) throws {
        guard !spans.isEmpty else { throw DomainModelError.emptyEvidence }
        guard Set(spans.map(\.observationID)).isSubset(of: Set(evidence.observationIDs)) else {
            throw DomainModelError.unknownObservation
        }
        self.id = id
        self.evidence = evidence
        self.family = family
        self.severity = severity
        self.assessment = assessment
        self.spans = spans
    }

    public var description: String {
        "SecretDetection(rule: \(evidence.ruleID.rawValue), family: \(family.rawValue), "
            + "assessment: \(assessment), spans: \(spans.count))"
    }
    public var debugDescription: String { description }
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

/// How a candidate's rectangles were derived. Review UIs should flag `lineFallback`.
public enum CandidateGeometry: Int, Comparable, Equatable, Sendable {
    /// The value starts and ends on OCR word boundaries; rectangles are word boxes.
    case wordAligned = 0
    /// An edge falls inside an OCR word; it was placed on a character cell measured from the
    /// image pixels.
    case measured = 1
    /// Sub-word geometry could not be measured, so the whole OCR word (or line) is covered,
    /// including any key or label. Needs review.
    case lineFallback = 2
    /// Drawn by the user.
    case manual = 3

    public static func < (lhs: CandidateGeometry, rhs: CandidateGeometry) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// One reviewable redaction. Generated candidates retain evidence; manual candidates do not.
///
/// A candidate may hold several rectangles (for example a value wrapped across lines). Review
/// acts on the candidate as a whole; rendering covers every region of an included or manual
/// candidate.
public struct RedactionCandidate: Identifiable, Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible {
    public let id: UUID
    public let regions: [RedactionRegion]
    /// Combined provenance of every finding merged into this candidate. Empty for manual ones.
    public let evidence: [DetectionEvidence]
    /// The `SecretDetection` IDs this candidate was composed from.
    public let detectionIDs: [UUID]
    public let geometry: CandidateGeometry
    public let assessment: DetectionAssessment?
    public let severity: SecretSeverity?
    public let disposition: RedactionDisposition

    public init(
        id: UUID = UUID(),
        regions: [RedactionRegion],
        evidence: [DetectionEvidence],
        detectionIDs: [UUID] = [],
        geometry: CandidateGeometry = .wordAligned,
        assessment: DetectionAssessment = .likely,
        severity: SecretSeverity = .high,
        disposition: RedactionDisposition = .pending
    ) throws {
        guard disposition != .manual, geometry != .manual else {
            throw DomainModelError.invalidCandidateDisposition
        }
        guard !regions.isEmpty, !evidence.isEmpty else { throw DomainModelError.emptyEvidence }
        self.id = id
        self.regions = regions
        self.evidence = evidence
        self.detectionIDs = detectionIDs
        self.geometry = geometry
        self.assessment = assessment
        self.severity = severity
        self.disposition = disposition
    }

    /// Convenience for a single-region generated candidate.
    public init(
        id: UUID = UUID(),
        region: RedactionRegion,
        evidence: DetectionEvidence,
        disposition: RedactionDisposition = .pending
    ) throws {
        try self.init(id: id, regions: [region], evidence: [evidence], disposition: disposition)
    }

    public static func manual(id: UUID = UUID(), region: RedactionRegion) -> RedactionCandidate {
        RedactionCandidate(manualID: id, region: region)
    }

    private init(manualID: UUID, region: RedactionRegion) {
        id = manualID
        regions = [region]
        evidence = []
        detectionIDs = []
        geometry = .manual
        assessment = nil
        severity = nil
        disposition = .manual
    }

    public var isManual: Bool { disposition == .manual }

    /// True when exact sub-word geometry was unavailable and a whole word or line is covered.
    public var needsGeometryReview: Bool { geometry == .lineFallback }

    public func settingDisposition(_ disposition: RedactionDisposition) throws -> RedactionCandidate {
        guard !isManual, disposition != .manual,
              let assessment, let severity else {
            throw DomainModelError.invalidCandidateTransition
        }
        return try RedactionCandidate(
            id: id,
            regions: regions,
            evidence: evidence,
            detectionIDs: detectionIDs,
            geometry: geometry,
            assessment: assessment,
            severity: severity,
            disposition: disposition
        )
    }

    public var description: String {
        "RedactionCandidate(id: \(id), disposition: \(disposition), regions: \(regions.count), "
            + "geometry: \(geometry))"
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
    case secretsDetected
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
    /// Detector findings over `observations`. Cleared whenever observations are replaced.
    public let detections: [SecretDetection]
    public let candidates: [RedactionCandidate]
    public let userEdits: [RedactionEdit]
    public let processingState: RedactionProcessingState

    public init(
        sourceIdentity: SourceImageIdentity,
        pixelDimensions: PixelDimensions,
        observations: [OCRObservation] = [],
        detections: [SecretDetection] = [],
        candidates: [RedactionCandidate] = [],
        userEdits: [RedactionEdit] = [],
        processingState: RedactionProcessingState = .imported
    ) throws {
        guard Set(observations.map(\.id)).count == observations.count,
              Set(detections.map(\.id)).count == detections.count,
              Set(candidates.map(\.id)).count == candidates.count,
              Set(candidates.flatMap { $0.regions.map(\.id) }).count
                == candidates.map(\.regions.count).reduce(0, +),
              Set(userEdits.map(\.id)).count == userEdits.count else {
            throw DomainModelError.duplicateIdentifier
        }

        let observationIDs = Set(observations.map(\.id))
        let textLengths = Dictionary(
            uniqueKeysWithValues: observations.map { ($0.id, $0.text.utf16.count) }
        )
        for detection in detections {
            guard Set(detection.evidence.observationIDs).isSubset(of: observationIDs) else {
                throw DomainModelError.unknownObservation
            }
            for span in detection.spans {
                guard let length = textLengths[span.observationID],
                      span.utf16Range.lowerBound >= 0,
                      span.utf16Range.upperBound <= length else {
                    throw DomainModelError.spanOutOfBounds
                }
            }
        }
        let detectionIDs = Set(detections.map(\.id))
        for candidate in candidates {
            guard candidate.regions.allSatisfy({ $0.rect.isContained(in: pixelDimensions) }) else {
                throw DomainModelError.regionOutOfBounds
            }
            guard candidate.evidence.allSatisfy({
                Set($0.observationIDs).isSubset(of: observationIDs)
            }) else {
                throw DomainModelError.unknownObservation
            }
            guard Set(candidate.detectionIDs).isSubset(of: detectionIDs) else {
                throw DomainModelError.unknownDetection
            }
        }

        let candidateIDs = Set(candidates.map(\.id))
        guard userEdits.allSatisfy({ candidateIDs.contains($0.candidateID) }) else {
            throw DomainModelError.candidateNotFound
        }

        self.sourceIdentity = sourceIdentity
        self.pixelDimensions = pixelDimensions
        self.observations = observations
        self.detections = detections
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

    /// Stores detector findings for the current observations. Clears candidates and edits,
    /// which were derived from earlier findings.
    public func replacingDetections(
        _ detections: [SecretDetection],
        processingState: RedactionProcessingState = .secretsDetected
    ) throws -> RedactionDocument {
        try RedactionDocument(
            sourceIdentity: sourceIdentity,
            pixelDimensions: pixelDimensions,
            observations: observations,
            detections: detections,
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
            detections: detections,
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
        guard candidates[index].disposition != disposition else { return self }
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
            detections: detections,
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
            detections: detections,
            candidates: candidates + [candidate],
            userEdits: userEdits + [edit],
            processingState: processingState
        )
    }

    public func updatingManualRegion(_ rect: ImageRect, for candidateID: UUID) throws -> Self {
        guard let index = candidates.firstIndex(where: { $0.id == candidateID }) else {
            throw DomainModelError.candidateNotFound
        }
        let candidate = candidates[index]
        guard candidate.isManual, let region = candidate.regions.first else {
            throw DomainModelError.invalidCandidateTransition
        }
        guard region.rect != rect else { return self }
        var updated = candidates
        updated[index] = .manual(id: candidateID, region: RedactionRegion(id: region.id, rect: rect))
        return try applyingManualChange(updated, edits: userEdits + [
            RedactionEdit(candidateID: candidateID, disposition: .manual)
        ])
    }

    public func removingManualCandidate(_ candidateID: UUID) throws -> Self {
        guard let candidate = candidates.first(where: { $0.id == candidateID }) else {
            throw DomainModelError.candidateNotFound
        }
        guard candidate.isManual else { throw DomainModelError.invalidCandidateTransition }
        return try applyingManualChange(
            candidates.filter { $0.id != candidateID },
            edits: userEdits.filter { $0.candidateID != candidateID }
        )
    }

    private func applyingManualChange(_ candidates: [RedactionCandidate], edits: [RedactionEdit]) throws -> Self {
        try Self(sourceIdentity: sourceIdentity, pixelDimensions: pixelDimensions,
                 observations: observations, detections: detections, candidates: candidates,
                 userEdits: edits, processingState: processingState)
    }

    public var description: String {
        "RedactionDocument(source: \(sourceIdentity.rawValue), observations: \(observations.count), "
            + "detections: \(detections.count), candidates: \(candidates.count))"
    }
    public var debugDescription: String { description }
}
