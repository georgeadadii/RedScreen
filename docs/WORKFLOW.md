# Import-to-export workflow

`ScreenshotImportController` orchestrates the Phase 1 pipeline: import, normalize, OCR, detect,
compose, review, render, save or copy, and reset. `workflowState` is the single explicit state.
It is derived from the controller's stage tokens on every read, so it cannot disagree with them.

| State | Meaning | Leaves to |
| --- | --- | --- |
| `idle` | No document is open. | `loading` |
| `loading` | An import is decoding and normalizing a file. | `recognizing`, `failed`, `canceled`, or the open document's state |
| `recognizing` | OCR, secret detection, and candidate composition are running. | `reviewing`, `failed`, `canceled` |
| `reviewing` | Findings and manual rectangles are editable. | `rendering`, `exporting`, `loading`, `idle` |
| `rendering` | A reviewed render is in flight. | `reviewing` |
| `exporting` | A confirmed save is being written. | `reviewing` |
| `failed(…)` | Import failed with no document open, or recognition or detection failed. | `recognizing` (Retry), `loading`, `idle` |
| `canceled` | The user canceled an import with no document open, or canceled processing. | `recognizing` (Retry), `loading`, `idle` |

## Defined behaviours

- **Cancel** (`cancelProcessing()`, the Cancel button or Escape):
  - During import, it abandons that import. Any open document stays unchanged.
  - During recognition, it stops OCR and detection and clears partial results. The document stays
    open with no findings, and it cannot be previewed or exported until Retry.
- **Retry** (`retryRecognition()`) restarts recognition after a failure or a cancel.
- **Rapid re-import:** each import gets a generation token, and only the newest one is applied.
  Earlier imports never start recognition, even if they finish later.
- **Re-import during processing:** recognition and detection results are tagged with their
  session. Results for a replaced document are discarded.
- **Close during processing:** closing clears the session and cancels in-flight work. A late
  import, recognition, or render result is discarded, and a late render throws
  `CancellationError`.
- **Edit during rendering:** the render is refused because its review revision is stale.
- **Failure reporting:** import failures on an open document appear as `lastError`, and the
  document keeps its state. Messages are fixed strings and never contain paths or text.

`WorkflowStateTests` drives each transition with gated fakes. `Phase1WorkflowIntegrationTests`
runs the whole pipeline with production components.
