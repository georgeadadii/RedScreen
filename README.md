# RedScreen

RedScreen is a privacy-first native macOS menu bar utility for permanently redacting sensitive
information from screenshots. Processing is designed to remain entirely on the Mac.

This repository contains screenshot import, on-device OCR, developer-secret detection, reviewable
redaction candidates, and a tested solid-pixel renderer, backed by an in-memory image lifecycle
and privacy-safe logging. The app supports manual redaction review and a flattened on-device preview. Saving and copying
redacted images and native screenshot capture are planned.

`main` is the integration branch. See [Contributing](CONTRIBUTING.md) for the branch workflow,
required checks, and local validation commands.

## Technology stack

- Swift 6
- SwiftUI and AppKit
- XCTest / XCUITest
- Native Xcode project with no third-party dependencies
- Minimum deployment target: macOS 14.0

## Prerequisites

- macOS 14 or later
- Xcode 16 or later with the macOS platform and required system components installed
- Xcode Command Line Tools selected (`xcode-select -p` should point into Xcode)
- GNU Make (included with Apple's developer tools)

The initial project was authored with Xcode 27.0 and Apple Swift 6.4. No package resolution or
network access is required.

## Clone and build

The primary development workflow is terminal-based and works well from VS Code or Codex:

```sh
git clone https://github.com/georgeadadii/RedScreen.git
cd RedScreen
make build
```

The Debug application is created at:

```sh
.build/DerivedData/Build/Products/Debug/RedScreen.app
```

No package resolution or third-party dependency download is required. The equivalent direct command
is:

```sh
xcodebuild -project RedScreen.xcodeproj -scheme RedScreen \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData build
```

## Launch locally

Build and launch a fresh instance:

```sh
make run
```

RedScreen appears as a shield icon in the macOS menu bar. It opens no window at launch and,
because it is configured as an `LSUIElement` agent application, it does not appear in the Dock.
Closing the popover leaves the utility running.

Choose **Import Screenshot…** (or drop a PNG, JPEG, or HEIC file on it) to open a screenshot in
the document window. Text is then recognized on device, checked for developer secrets, and
turned into redaction rectangles: the footer shows how many likely secrets were found, and
**Highlight Findings** draws the proposed redactions (filled red: included, orange: to review,
dashed: whole word covered, needs review). **Show Text Regions** outlines all recognized text. Synthetic screenshots to try are in `RedScreenCoreTests/Fixtures/images`.

## Install into Applications

Build the Release configuration and copy it into `/Applications`:

```sh
make install
```

If the current user cannot write to `/Applications`, run the final copy explicitly with
administrator privileges:

```sh
make build CONFIGURATION=Release
sudo ditto .build/DerivedData/Build/Products/Release/RedScreen.app \
  /Applications/RedScreen.app
```

Local builds use Xcode's normal development/ad-hoc signing behavior. Distribution outside the local
Mac will eventually require Developer ID signing and notarization.

## Run tests

The shared scheme runs both the core unit tests and app UI tests:

```sh
make test
```

Neither test suite reads user files, uses real screenshots, requests screen-recording permission,
or accesses the network.

Core tests use a generated corpus of synthetic developer screenshots with machine-readable ground
truth. To regenerate it after changing a scenario, run the sandboxed generator:

```sh
make fixtures
```

See [Synthetic screenshot fixtures](docs/TEST_FIXTURES.md) for the corpus layout, ground-truth
schema, comparison helpers, and synthetic-value policy.

## Architecture

```text
RedScreen/
├── App/                    # MenuBarExtra entry point and application actions
└── UI/                     # Menu bar popover and on-demand document window
RedScreenCore/
├── Domain/                 # Documents, geometry, and framework-independent value types
├── Platform/               # ImageIO import, container integrity checks, Vision OCR
└── Services/               # Import controller, secret detector, candidate composer
    ├── ImageImporting
    ├── TextRecognizing
    ├── SensitiveInformationDetecting
    ├── RedactionRendering
    └── ImageExporting
RedScreenCoreTests/         # Core tests without launching SwiftUI
├── Fixtures/               # Generated synthetic screenshots and ground truth
└── FixtureSupport/         # Fixture schema, scenarios, renderer, loaders, and matchers
RedScreenUITests/           # Launch and empty-state UI tests
Tools/FixtureGenerator/     # Sandboxed generator for the synthetic fixture corpus
```

The app target depends on `RedScreenCore`; the core module does not depend on SwiftUI. Future
platform implementations can be injected behind the service protocols, while tests can use small
test doubles. This initial phase deliberately provides no production implementation of those
capabilities.

The application scene is a window-style SwiftUI `MenuBarExtra`, not a `WindowGroup`. Its compact
content is isolated in `MenuBarContentView`. A later issue can expand this popover or have the app
composition layer present a temporary floating review panel without coupling that UI to the core
pipeline or introducing a permanent main window.

`SecureImageSessionLifecycle` is the single owner of source bytes and derived sensitive state for
the open document. See [Privacy boundaries and secure image lifecycle](docs/PRIVACY_AND_SECURITY.md)
for the threat model, invariants, and operating-system limitations that later pipeline work must
preserve.

The immutable document model, canonical top-left pixel coordinate space, OCR origin conversion,
aspect-fit presentation mapping, raster rounding policy, and Phase 1 service contracts are defined
in [Redaction document and coordinate architecture](docs/DOCUMENT_AND_GEOMETRY.md).

## Privacy and security

- All future screenshot processing is intended to happen locally.
- The app sandbox is enabled with no additional entitlements.
- No network client, analytics, telemetry, crash-upload, cloud SDK, or third-party dependency is
  present.
- Sensitive image bytes, OCR text, file paths, detected values, and clipboard contents must never
  be logged.
- Production logging accepts predefined event identifiers and non-sensitive counts only.
- No source image, OCR result, detection result, preview, or undo state is autosaved.
- Import-to-export processing must not create an application-managed plaintext temporary image.
- File access is granted only through explicit user interaction: the Open panel or drag-and-drop
  for import and the Save panel for export (`com.apple.security.files.user-selected.read-write`).
  Imported files are read once into memory and are never copied, cached, or added to recent
  documents. Only the flattened, metadata-scrubbed redacted PNG is saved or copied.

## Current status

Issues #1 and #2 establish the application architecture and executable privacy boundaries.
Issue #3 defines the shared document, geometry, and service contracts, and issue #4 adds the
synthetic screenshot corpus and test utilities that later pipeline work is measured against.
Issue #5 adds safe screenshot import: the Open panel and drag-and-drop lead to a validated,
orientation-normalized, in-memory image shown in a document window (see
[Screenshot import](docs/IMAGE_IMPORT.md)). Issue #6 adds on-device Apple Vision OCR with
cancellation, stale-result rejection, and corpus accuracy gates (see
[On-device text recognition](docs/TEXT_RECOGNITION.md)). Issue #7 adds context-sensitive
developer secret detection (see [Developer secret detection](docs/SECRET_DETECTION.md)), and
issue #8 composes findings into padded, reviewable redaction candidates with full pixel coverage
on the corpus (see [Redaction candidate composition](docs/CANDIDATE_COMPOSITION.md)). Issue #9
(RED-5) adds irreversible solid-pixel rendering into a new in-memory raster with exact opaque
fills (see [Redaction rendering](docs/REDACTION_RENDERING.md)). Issue #10 (RED-6) adds
[manual review and editing](docs/REDACTION_REVIEW.md) with a gated flattened preview. Issue #11
(RED-7) adds [saving and copying](docs/IMAGE_EXPORT.md) of the reviewed, flattened,
metadata-scrubbed PNG. Issue #12 (RED-8) joins these stages into an explicit, cancelable
[workflow state machine](docs/WORKFLOW.md) with end-to-end, privacy, and timing gates, and records
the [Phase 1 readiness checklist](docs/PHASE1_READINESS.md). Screenshot capture and settings remain
for later issues.

