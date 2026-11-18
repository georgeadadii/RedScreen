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
  - `.wordAligned`: every edge is an OCR word boundary.
  - `.measured`: an edge falls inside an OCR word (`KEY=value`) and was placed on a character
    cell measured from the image pixels.
  - `.lineFallback`: sub-word geometry could not be measured, so the whole OCR word (or line) is
    covered, key included.
  - `.manual`: drawn by the user.

  `needsGeometryReview` is true for `.lineFallback`; the review UI (#10) should flag it.
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

Vision reports boxes for whole words only. `KEY=value` with no spaces is one word, so where the
value starts cannot come from OCR. The first version estimated it by counting characters and
adding a safety margin. On real editor screenshots that estimate covered keys and could leave the
start or end of a value exposed. Both edges are now placed as follows.

1. **Word boundary.** If the value starts or ends where an OCR word does, that word box edge is
   used. It is extended to the word's measured ink, so a slightly narrow OCR box cannot clip
   glyphs.
2. **Measured.** If an edge falls inside a word, `GlyphGridLocator` measures the pixels.
   - **Why it works:** code editors and terminals use fixed-width fonts, so every character
     occupies one cell of the same width.
   - **How it fits:**
     - Ink is classified against the line's dominant colour, using the upper ~78% of the line so
       underscores and descenders, which join neighbouring cells, are ignored.
     - The cell grid is anchored on the word's ink: on its left end first, and on its right end
       if that fails, because OCR boxes sometimes start inside a neighbouring glyph.
     - The fit searches cell widths for boundaries that fall in the gaps between glyphs. At 1x it
       scores the emptiest column within half a pixel, because anti-aliasing smears glyph edges.
   - **When it accepts a grid:**
     - boundaries must be clearly emptier than the glyphs;
     - at most 10% of letter cells may be empty;
     - spaces must be blank, except at the outermost cell where a neighbouring glyph may overlap
       the box;
     - `_`, `.` and `,` sit at or below the baseline and are ignored.
   - **Result:** the edge lands exactly on the cell boundary, padded by 6% of a cell.
3. **Whole-word fallback.** With no pixels, or when the grid is not accepted (proportional text,
   wide characters, noise), the whole OCR word is covered, key included, and the candidate is
   flagged for review. **Partially covering a secret is never an acceptable outcome**, so
   uncertainty always resolves toward covering more.

Vision occasionally fails to box one word of a line. Text without a word box gets a synthesized
unit spanning from the previous word box to the next one, or to the end of the line. Ink is only
extended past a box edge where the text has a space on that side, so a word such as `PASSWORD`
that follows `DEPLOY_` cannot absorb the neighbouring word.

Private key blocks are covered as **one rectangle from BEGIN to END**, so a key line OCR missed
or boxed narrowly inside the block is still covered.

Padding:
- **Vertical:** `max(2 px, 8% of the line height)`, small enough not to clip tightly spaced
  editor lines.
- **Horizontal:** 2 px at word boundaries and fallbacks, 6% of a cell at measured edges.

Rectangles are then clamped to the image and checked to be finite and positive.

## Merging and ordering

- Findings whose rectangles overlap **on the same line** (vertical overlap of at least half the
  shorter height) become one candidate with combined evidence and detection IDs. Rectangles on
  different lines are never joined: in tightly spaced editors, padded boxes of adjacent lines
  touch, and joining them once covered the next line's key.
- The merged candidate takes the worst geometry, the strongest assessment and the highest
  severity.
- Same-line overlapping rectangles inside a candidate are merged into their union.
- Candidates and their regions are sorted in reading order (top, then left), so keyboard
  navigation and tests are stable.

## Policy

`CandidateCompositionPolicy.standard`:

| Setting | Value |
| --- | --- |
| `minimumPaddingPixels` | 2 |
| `paddingFractionOfLineHeight` | 0.08 |
| `measuredEdgePaddingFraction` | 0.06 |

The grid locator's acceptance limits are `maximumBoundaryInkRatio` (0.3),
`maximumEmptyCellFraction` (0.1) and `wordGapCells` (0.75).

## Coverage on the synthetic corpus

`CandidateCoverageEvaluationTests` measure coverage at **pixel level** on all 34 rendered
fixtures:

- **Secret coverage:** every ink pixel inside a sensitive span must be covered.
- **Key/label ink obscured:** the share of ink outside the secret on the same line as a secret
  (`DATABASE_PASSWORD=`, quotes) that candidates cover. This is the regression gate for the
  reported bug: at most 2% with Vision OCR.
- **Unrelated ink obscured:** the share of all non-secret ink covered.

The corpus includes editor-style renderings modelled on a real `.env` screenshot:
- a line-number gutter and syntax colours;
- tight line spacing;
- quoted values containing spaces;
- adjacent secrets;
- a pooled database URL;
- Menlo, Monaco and Courier New fonts.

Measured 2026-11-18:

| Input | Secret ink covered | Key/label ink obscured | Unrelated ink obscured | Geometry |
| --- | --- | --- | --- | --- |
| Ground-truth text | 137,648 / 137,648 (100%) | 5.1% | 1.6% | 14 word, 74 measured, 4 fallback |
| Vision OCR, end to end | 137,648 / 137,648 (100%) | **1.6%** | 0.7% | 26 word, 62 measured, 4 fallback |

**Before this fix**, on the same corpus with Vision OCR:
- secret coverage was 99.53%: part of one value was exposed;
- 9.4% of key ink was obscured, up to 49% on adjacent editor lines.

The remaining fallbacks are deliberate:
- **Proportional prose** in the support-ticket fixture. With ground-truth text it has no word
  boxes, so the whole line is covered; that accounts for most of the 5.1%.
- **A Courier New line at 2x** that Vision split mid-token with an overlapping box
  (`export SERVICE` / `_API_KEY=…`). Part of that key is covered, the value is fully covered,
  and the candidate is flagged for review.

## Tests

- **Geometry:**
  - exact word-aligned spans;
  - whole-word coverage when pixels are unavailable;
  - measured edges on every monospace fixture: within 0.05 of a character of the value start,
    never more than 0.35 of a character into the key, and covering the end;
  - proportional text falling back to the whole line;
  - adjacent-line secrets never merged;
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
