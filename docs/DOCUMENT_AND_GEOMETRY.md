# Redaction document and coordinate architecture

This document defines the contracts shared by Phase 1 import, OCR, detection, review, rendering,
and export work. Future implementations must use these core types rather than introducing
framework-specific geometry or parallel sensitive state.

## Ownership and document snapshots

`SecureImageSession` is the sole owner of source, decoded, preview, and clipboard image buffers.
`ScreenshotImage` and `DecodedPixels` use immutable reference semantics so ownership and release can
be observed without copying buffer contents into the document.

`RedactionDocument` is an immutable, `Sendable` value snapshot containing a non-sensitive source
identity, upright pixel dimensions, OCR observations, review candidates, non-sensitive edit
records, and processing state. Replacing observations, candidates, or dispositions returns a new
validated snapshot. The lifecycle stores exactly one current document; it does not maintain
parallel OCR, detection, or undo collections.

Sensitive runtime types—including buffers, OCR observations, imported images, export destinations,
and documents—are deliberately not `Codable`. Only non-sensitive stable identifiers such as
`SourceImageIdentity` and `DetectorRuleID` are codable. Descriptions of sensitive types redact image
bytes, OCR text, and file locations.

## Coordinate spaces

RedScreen uses three separate coordinate spaces:

1. `NormalizedRect` represents OCR input in unit coordinates. Its values are finite and contained
   in `[0, 1]`. The producer origin is supplied explicitly as top-left or bottom-left; no implicit
   Vision-origin assumption is allowed.
2. `ImageRect` is the canonical processing geometry. Its units are physical pixels in the upright,
   orientation-normalized source image. The origin is top-left, `x` increases rightward, `y`
   increases downward, and edges remain continuous `Double` values.
3. `PresentationRect` is framework-neutral UI geometry measured in view points with a top-left
   origin. `AspectFitGeometry` owns the scale and letterbox offsets. Core does not import SwiftUI,
   AppKit, Core Graphics, or Vision; UI adapters may convert presentation values at their boundary.

Importers must normalize image orientation before publishing `PixelDimensions`. OCR adapters must
retain the OCR producer's normalized origin. Detection and composition convert observations into
canonical image rectangles. Review and rendering consume the same `RedactionRegion` model for both
detector-generated and manual candidates.

## Rounding and tolerance

Normalized-to-image and image-to-presentation conversions do not round. Continuous round trips are
expected to agree within `1e-9` pixels or normalized units, allowing for IEEE-754 arithmetic.

Only the renderer should request integer coverage. `enclosingPixelRect` rounds minimum edges down
with `floor`, maximum edges up with `ceil`, and clamps to image dimensions. This may expand a region
by less than one pixel per edge and intentionally favors complete redaction over under-coverage.
Integer rectangles use half-open edges: `[x, x + width) × [y, y + height)`.

Invalid or ambiguous geometry is rejected: dimensions and rectangle sizes must be positive; values
must be finite; normalized and raster rectangles must stay within their declared bounds; and view
rectangles must fall inside the aspect-fit image content rather than a letterbox area.

## Candidate provenance and state

`DetectionEvidence` stores a detector rule ID, confidence, and stable OCR observation IDs. It never
copies the matched OCR string. This is sufficient to explain which observations and rule produced a
candidate while keeping one copy of sensitive text in the document.

Generated candidates transition among `pending`, `included`, and `excluded` while preserving their
identity, region, and evidence. Manual candidates use the same `RedactionCandidate` and
`RedactionRegion` review/render model with disposition `manual` and no detector evidence. Manual
candidates cannot masquerade as detector output, and generated candidates cannot transition to
manual.

## Service boundary

The six `Sendable` protocols are `ImageImporter`, `TextRecognizer`, `SecretDetector`,
`CandidateComposer`, `RedactionRenderer`, and `ImageExporter`. Implementations belong in later
issues. They communicate only through `RedScreenCore` types and must remain local-only. Import and
export URLs are transient call arguments and must not be retained in `RedactionDocument`.
