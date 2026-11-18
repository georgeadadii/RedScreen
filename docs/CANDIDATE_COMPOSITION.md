# Redaction candidate composition

Issue #8 turns detector findings into reviewable redaction candidates: minimal, padded,
in-bounds image rectangles with provenance. `GeometricCandidateComposer`
(`RedScreenCore/Services/Composition`) runs after secret detection. The document then moves to
`readyForReview`.

## Candidate model

`RedactionCandidate` is shared by generated and manual redactions. Each candidate carries:

- `regions`: one or more rectangles. A value wrapped across lines is **one** candidate with a
  rectangle per line.
- `evidence` and `detectionIDs`: the combined provenance of every finding merged into it (rule
  IDs, observation IDs, confidences). No matched text is copied.
- `geometry`, which says how the rectangles were derived:
  - `.wordAligned`: the value starts and ends on OCR word boundaries, so word boxes are used.
  - `.estimated`: the value is part of an OCR word or line, for example `KEY=value` without
    spaces, so its extent is interpolated.
  - `.lineFallback`: no usable sub-line geometry, so the whole line is covered.
  - `.manual`: drawn by the user.

  `needsGeometryReview` is true for the estimated and fallback kinds; the review UI (#10) should
  flag them.
- `assessment` and `severity` from the strongest merged finding.
- `disposition`:
  - likely findings start **`included`**, because over-coverage is the safe default;
  - findings needing review start `pending`;
  - manual candidates are `manual`.

The document validates every candidate:
- every region lies within the image;
- evidence references known observations;
- `detectionIDs` reference the document's detections.

## Geometry

For each detected span:

1. **Word boxes.** If the span starts and ends on boundaries of the observation's word
   segments, the segments' union is used.
2. **Estimation.** Vision reports word-level boxes only, so values inside a word are
   interpolated from character positions within the boundary word box. Without word boxes the
   line box is used instead; it hugs visible text, so indentation is skipped. Each estimated edge
   is widened by a safety margin:
   - **0.6 characters**, plus
   - **0.1 characters per character of distance** from the nearest known edge, capped at
     **1.2 characters**.

   Uniform widths are exact for monospace text but drift in proportional fonts the further they
   are from an anchor, which is what the growing margin covers.
3. **Fallback.** When neither works, for example a blank line or a degenerate range, the whole
   line is used and the candidate is flagged.

Private key blocks are covered as **one rectangle from BEGIN to END**, so a key line OCR missed
or boxed narrowly inside the block is still covered.

Every rectangle is padded by `max(2 px, 15% of the line height)`, which scales with 1x and 2x
screenshots. It is then clamped to the image and checked to be finite and positive.

## Merging and ordering

- Findings whose rectangles overlap become one candidate with combined evidence and detection
  IDs.
- The merged candidate takes the worst geometry, the strongest assessment and the highest
  severity.
- Overlapping rectangles inside a candidate are merged into their union.
- Candidates and their regions are sorted in reading order (top, then left), so keyboard
  navigation and tests are stable.

## Policy

`CandidateCompositionPolicy.standard`:

| Setting | Value |
| --- | --- |
| `minimumPaddingPixels` | 2 |
| `paddingFractionOfLineHeight` | 0.15 |
| `estimatedMarginCharacters` | 0.6 |
| `estimatedMarginGrowthPerCharacter` | 0.1 |
| `maximumMarginGrowthCharacters` | 1.2 |

The growth cap was chosen by measurement: 0.6 left part of a proportional-font password exposed,
and 1.0 is the smallest cap with full coverage. 1.2 adds headroom.

## Coverage on the synthetic corpus

`CandidateCoverageEvaluationTests` measure coverage at **pixel level** on all 28 rendered
fixtures:
- **Secret coverage:** every ink pixel inside a sensitive span must be covered by a candidate.
- **Unrelated obscured:** the share of ink outside sensitive and ambiguous spans (labels, benign
  values, prose) that candidates cover.

Measured 2026-11-18:

| Input | Secret ink covered | Unrelated ink obscured | Geometry |
| --- | --- | --- | --- |
| Ground-truth text | 106,589 / 106,589 (100%) | 1.3% | all estimated (no word boxes) |
| Vision OCR, end to end | 106,589 / 106,589 (100%) | 1.4% | 24 word-aligned, 38 estimated |

The gates are 100% secret coverage, at most 5% unrelated ink obscured on ground-truth text, and
at most 8% on Vision OCR. The most over-redacted fixture, `env-file-dark-2x`, hides about 5% of
its unrelated ink: the estimate's safety margin reaches one or two characters into labels such as
`…PASSWORD=`.

## Tests

- **Geometry:**
  - exact word-aligned spans;
  - sub-word estimation (monospace exactness, indentation);
  - whole-line fallback;
  - wrapped values grouped under one candidate;
  - private key block cover;
  - overlap merging with combined evidence;
  - reading order and default dispositions;
  - padding scale and edge clamping;
  - unknown observations and detections rejected.
- **Property:** 300 seeded random inputs, mixing Unicode and both box origins, always produce
  finite, positive, in-bounds rectangles. The output is deterministic and every detection is
  represented.
- **Pipeline:** composed candidates are stored `readyForReview` with provenance back to the
  detections.
