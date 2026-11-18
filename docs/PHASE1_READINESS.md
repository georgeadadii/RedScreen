# Phase 1 readiness checklist

Status of the Phase 1 MVP (import, detect, review, redact, save or copy) against its
correctness, privacy, performance, and accessibility gates. Recorded on 2026-11-18 for RED-8
(GitHub #12). Update the measurements whenever a detector, renderer, corpus, or toolchain changes.

## Environment

- **CI:** GitHub `macos-26` (arm64) runner image, Xcode pinned to **26.6** in
  `.github/workflows/ci.yml`. CI runs `make build` and `make test-core`, which is every
  non-interactive test, and fails the job if any workflow uploads or caches artifacts.
- **Local baseline machine:** Apple M4, macOS 26.6.2, Xcode 27.2, Debug configuration.
- **UI tests:** `make test` requires a logged-in desktop session, so they run locally, not in CI.

## Correctness

| Gate | Target | Measured | Source |
| --- | --- | --- | --- |
| Sensitive recall, ground-truth text | 1.00 | 34/34 (1.000) | `SecretDetectorCorpusEvaluationTests` |
| Likely-classification recall, ground truth | ≥ 0.90 | 34/34 (1.000) | same |
| Precision, ground truth | ≥ 0.90 | 46/46 (1.000) | same |
| Ambiguous values surfaced for review | ≥ 0.80 | 12/12 (1.000) | same |
| Benign-fixture hits | 0 | 0 | same |
| Sensitive recall, Vision OCR end to end | ≥ 0.85 | 34/34 (1.000) | same |
| Precision, Vision OCR end to end | ≥ 0.85 | 46/46 (1.000) | same |
| Secret ink covered by candidates, Vision OCR | 1.00 | 137648/137648 px (1.0000) | `CandidateCoverageEvaluationTests` |
| Unrelated ink obscured, Vision OCR | ≤ 0.08 | 4188/583691 px (0.0072) | same |
| Unrelated ink obscured, ground truth | ≤ 0.05 | 9372/583691 px (0.0161) | same |
| Import → detect → edit → save and copy on a clean checkout | every secret's ink pixels opaque black in the saved and copied PNG | pass | `Phase1WorkflowIntegrationTests` |
| Cancel, retry, rapid re-import, close during processing | defined and tested | pass | `WorkflowStateTests`, [workflow](WORKFLOW.md) |

The corpus has 34 synthetic screenshots (17 scenes at 1x and 2x) and 34 sensitive spans.

## Performance baselines

Single-run wall-clock times in milliseconds from `Phase1WorkflowIntegrationTests` (Debug build,
baseline machine). CI enforces loose ceilings (for example OCR under 20 s and render under 2 s)
that catch regressions without flaking on shared runners.

| Screenshot | Size | Import | OCR | Detect | Compose | Render | Encode |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `terminal-wrapped-url-dark-1x` (smallest) | 400×172 | 0.8 | 35.2 | 0.3 | 0.4 | 0.1 | 0.6 |
| `editor-env-vscode-dark-2x` (largest) | 1800×658 | 7.1 | 190.4 | 1.0 | 5.7 | 0.3 | 7.3 |
| Synthetic 5K Retina, 40 fills | 5120×2880 | n/a | n/a | n/a | n/a | 6.4 | 74.2 |

OCR dominates the time. `VisionTextRecognizerTests` also has XCTest `measure` performance tests
for a small and a large screenshot.

## Privacy and security requirements

| Requirement | Status | Evidence |
| --- | --- | --- |
| Processing stays on device, with no network calls | Satisfied | `testProductionCodeHasNoNetworkingOrImplicitPersistence` scans all production sources. The entitlements are exactly sandbox plus user-selected read-write. |
| No implicit persistence or recent documents | Satisfied | Same source scan, `ImageLifecyclePolicy` tests, and the window opts out of state restoration. |
| No application-created plaintext image or OCR-text files | Satisfied | The end-to-end run inventories the temporary, cache, and application-support directories and finds no new image or secret text. `testFileInventoryDetectsAnUnexpectedImage` proves the inventory works. |
| Output only from the flattened, reviewed render | Satisfied | `FlattenedRedactedImage` can be created only inside the core module. Stale renders are refused. See [export](IMAGE_EXPORT.md). |
| No inherited metadata or thumbnails | Satisfied | PNG chunk allowlist, verified by `ImageExportTests`. |
| Pasteboard holds only rendered image data | Satisfied | Pasteboard tests and the review UI test. |
| No partial or silently overwritten destination | Satisfied | Atomic-save failure-injection tests. |
| Logs contain no text, paths, or pixels | Satisfied | Closed-enum `PrivacySafeLogger`, plus logger tests. |
| User-facing errors contain no secret text or paths | Satisfied | Fixed messages for `ImageImportError`, `ImageExportError`, and recognition. The UI tests check import errors. |
| A stale async result never mutates a newer document | Satisfied | `WorkflowStateTests` and `TextRecognitionControllerTests`. |
| CI uploads no sensitive artifacts | Satisfied | No upload or cache steps, and a CI guard rejects them. Test output prints fixture IDs, counts, and timings only. |
| Secure memory erasure | Accepted limitation | Not guaranteed by Swift or macOS. See [privacy](PRIVACY_AND_SECURITY.md#operating-system-limitations). |
| Removal from other apps' clipboard history | Accepted limitation | Outside RedScreen's control. Only the redacted image is copied. |

## Release blockers

- **Manual QA pass not yet performed.** Phase 1 is not release-ready until the checklist below
  has been completed and recorded on real hardware.
- **Pinned Xcode not yet confirmed on CI.** This blocker clears when the first CI run of this
  change succeeds with `Xcode_26.6.app` selected.

## Manual QA checklist

Record the tester, date, macOS version, and display used for each item.

- [ ] **VoiceOver:**
  - [ ] The drop zone, import button, findings list, Include and Exclude, manual-rectangle steppers
    and delete, Preview, Save As, Copy, Cancel, and Retry are all announced with meaningful labels.
  - [ ] Findings never announce recognized values.
- [ ] **Keyboard only:**
  - [ ] Import (⌘O), move between findings (⌥↑ and ⌥↓), Include or Exclude, and Add Rectangle.
  - [ ] Adjust the rectangle with the steppers, Undo and Redo (⌘Z, ⇧⌘Z), Preview, Save As (⇧⌘S),
    Copy (⇧⌘C), Cancel (Esc), and Close (⌘W). No mouse is needed.
- [ ] **Light and dark mode:** overlays, the pending, included, and excluded colours, banners, and
  status text stay legible in both appearances and with Increase Contrast turned on.
- [ ] **Retina and non-Retina:** on a 1x external display and a 2x built-in display, drawn
  rectangles land on the intended pixels, and saved output matches the preview.
- [ ] **Large screenshots:** a 5K or 6K full-display capture imports, stays responsive while
  zoomed and panned, and saves and copies correctly. An image over the pixel budget is rejected
  with an actionable message.
- [ ] **Paste targets:** the copied image pastes correctly into Preview (New from Clipboard), a
  browser text field, and Slack or Mail.
- [ ] **Cancel and close:** cancel during import and during "Recognizing text…", then Retry.
  Close the window mid-processing, then reopen. No stale findings appear.
