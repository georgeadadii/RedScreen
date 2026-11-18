# On-device text recognition

Issue #6 extracts text and bounding boxes from the imported screenshot with Apple Vision, entirely
on the Mac.

## What the user sees

After an import succeeds, OCR starts automatically. The document window footer shows
**Recognizing text…** and then **N text regions**. **Show Text Regions** outlines what was found;
only geometry is drawn, never recognized text. If recognition fails, a banner explains the failure
and offers **Retry**. The image stays open either way.

## Settings and rationale

`VisionTextRecognizer` (`RedScreenCore/Platform`) runs one `VNRecognizeTextRequest`:

| Setting | Value | Why |
| --- | --- | --- |
| `recognitionLevel` | `.accurate` | Better on small monospace terminal and code text. |
| `usesLanguageCorrection` | `false` | Correction can rewrite secret-like strings into dictionary words, hiding them from detection. |
| `customWords` | `[]` | Nothing from screenshots is given to the recognizer, so there is no vocabulary to persist. |
| `recognitionLanguages` | `["en-US"]` | Deterministic results. |
| `automaticallyDetectsLanguage` | `false` | Deterministic results. |
| `minimumTextHeight` | `0` | Vision chooses; small UI text is kept. |

The request runs on the session's normalized pixels, wrapped as a `CGImage` with no copy to disk,
with orientation `.up`, because the importer has already made the pixels upright. Vision text
recognition runs on device; the recognizer has no networking, logging, or file access, and a test
checks its source for those APIs. Cancelling the calling task cancels the Vision request.

## Output and coordinates

Each Vision result becomes an `OCRObservation`. It has:
- a fresh, stable `UUID`;
- the top candidate's text;
- a confidence, clamped to `0...1`;
- its box, with **`boundingBoxOrigin = .bottomLeft`**.

Vision's normalized boxes can extend fractionally past the image, so they are clamped to
`[0, 1]`. Callers convert them to canonical top-left pixels with
`OCRObservation.imageRect(in:)`, which uses the core geometry helpers.

`segments` hold one `OCRTextSegment` per whitespace-delimited word: a UTF-16 range into the text
and a box in the same origin. **Vision's sub-range boxes are word-granular.** Requesting part of a
token such as `KEY=value` returns the whole token's box, so value-only redaction inside one token
needs the fallback planned in issue #8.

## Replacement and failures

`ScreenshotImportController` starts recognition after each successful import. Each run gets a
generation token:

- **A new document or a close cancels the run.** A result that still arrives is stored only if
  its session is still active, so a stale result can never populate another document.
- **A failed import doesn't stop the open document's OCR.**
- **On success** the document gets its observations and `processingState = .textRecognized`.
- **On failure** the document gets `.failed(.recognitionFailed)` and `recognitionStatus` becomes
  `.failed(...)`, a recoverable state that `retryRecognition()` clears.

Diagnostics go through `PrivacySafeLogger` and carry counts only:
- `text_recognized` carries the observation count;
- `text_recognition_duration_ms` carries the elapsed milliseconds;
- `text_recognition_failed` carries no payload.

Recognized text is never logged.

## Accuracy on the synthetic corpus

`VisionTextRecognizerTests.testRecognizesTheSyntheticCorpusWithinTolerances` runs Vision on all
28 fixtures.

**How a line is scored as found:**
- OCR lines that overlap it vertically by at least half the smaller height cover at least 80% of
  its horizontal extent;
- the OCR text contains the ground-truth text within a 10% character error rate, ignoring
  whitespace.

Vision's boxes hug the ink while ground-truth boxes span full font height, so 2D IoU is not used.
Lines with fewer than two visible characters are not scored, because Vision ignores isolated
glyphs such as `{` and `}`.

**Thresholds:** at least 85% of lines per fixture and at least 95% overall.

**Measured (2026-11-18, macOS 26, Apple Silicon): 268 of 272 lines (98.5%).** The remaining misses
are genuine OCR errors:
- dash runs in PEM armor read as em-dashes;
- asterisk masks with the wrong count;
- one 40-character hex SHA with several misread digits.

Reports list fixture and text box IDs only.

The same fixture is also recognized after import from PNG, JPEG, HEIC, and an EXIF-rotated JPEG.
All lines are found in each case, so orientation and coordinate conversion hold for every
supported format. The sensitive values in the side-by-side `.env` fixture are each covered by a
word segment.

## Performance

`testRecognitionPerformanceSmallScreenshot` and `testRecognitionPerformanceLargeScreenshot`
record clock time and memory with `measure`, without asserting on content. Set a baseline in
Xcode's test report to turn them into regression checks. On the development Mac a 1x terminal
fixture takes about 0.07 s, with a peak resident memory of about 166 MB including the test
process.
