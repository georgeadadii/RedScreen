# RedScreen

RedScreen is a privacy-first native macOS menu bar utility for permanently redacting sensitive
information from screenshots. Processing is designed to remain entirely on the Mac.

This repository contains screenshot import, on-device OCR, developer-secret detection, reviewable
redaction candidates, and a tested solid-pixel renderer, backed by an in-memory image lifecycle
and privacy-safe logging. The app supports manual redaction review, a flattened on-device preview, saving and copying the
redacted result, and native screen capture from the menu bar, the app menu, or an optional global
shortcut.

To use RedScreen, build it on your own Mac by following
[Set up RedScreen on your Mac](#set-up-redscreen-on-your-mac). It takes about 15 minutes the
first time, and everything is free.

`main` is the integration branch. See [Contributing](CONTRIBUTING.md) for the branch workflow,
required checks, and local validation commands.

## Technology stack

- Swift 6
- SwiftUI and AppKit
- XCTest / XCUITest
- Native Xcode project with no third-party dependencies
- Minimum deployment target: macOS 14.0

## Set up RedScreen on your Mac

RedScreen isn't distributed as a download. Each person builds it from this repository and signs
it with their own free Apple account. Signing is what lets macOS remember the Screen Recording
permission: without it, every rebuild looks like a new app and the permission is lost (see
[why](docs/CAPTURE_SHORTCUT.md#keeping-the-permission)). You do steps 1–7 once; updating is
step 8.

### What you need

| | Requirement |
| --- | --- |
| Mac | Any Mac with Apple silicon or Intel. RedScreen builds as a universal app. |
| macOS | 14 Sonoma or later to run RedScreen. Building also needs a macOS version that runs the Xcode below. |
| Xcode | Tested with Xcode 26.6 (used by CI) and 27.2. Older versions are untested. |
| Apple Account | A free one is enough. You do **not** need the paid Apple Developer Program. |

### 1. Install Xcode

Install Xcode from the App Store, open it once, and let it install its components. Then check
that the command-line tools use it:

```bash
xcode-select -p
```

It should print a path inside `Xcode.app`. If it prints `/Library/Developer/CommandLineTools`,
switch it (this asks for your password):

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

### 2. Get the code

```bash
git clone https://github.com/georgeadadii/RedScreen.git
```

```bash
cd RedScreen
```

### 3. Create your free signing certificate

1. Open **Xcode › Settings › Apple Accounts** (called **Accounts** in older versions), click
   **+**, and sign in with your Apple Account.
2. Select your **Personal Team**, click **Manage Certificates…**, then **+ › Apple
   Development**, and click **Done**.

### 4. Check that macOS trusts it

```bash
security find-identity -v -p codesigning
```

You should see `1 valid identities found`, with an `Apple Development: …` line.

If it says **0 valid identities found**, your keychain is missing Apple's intermediate
certificate (WWDR G3), which issues development certificates. Add it, then run the check again:

```bash
curl -fsSLo ~/Downloads/AppleWWDRCAG3.cer https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer
```

```bash
security add-certificates -k ~/Library/Keychains/login.keychain-db ~/Downloads/AppleWWDRCAG3.cer
```

### 5. Tell the build your team ID

This writes your team ID to `Config/Local.xcconfig`:

```bash
printf 'DEVELOPMENT_TEAM = %s\n' "$(security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject -nameopt multiline | awk -F'= ' '/organizationalUnitName/ {print $2}')" > Config/Local.xcconfig
```

Check it:

```bash
cat Config/Local.xcconfig
```

It should show `DEVELOPMENT_TEAM =` followed by a 10-character ID. That is the `OU` field of
your certificate, which is **not** the similar-looking code in parentheses in the certificate's
name. The file is git-ignored, so your team ID stays on your Mac.

### 6. Build and install

```bash
make install
```

This builds a Release copy, quits RedScreen if it's running, and installs
`/Applications/RedScreen.app`. At the end it prints how the copy is signed:
- **`TeamIdentifier=` with your team ID:** signing worked.
- **`Signature=adhoc`:** step 5 didn't take effect. Check `Config/Local.xcconfig`.

If macOS asks whether `codesign` may use your key, choose **Always Allow**.

### 7. Allow screen capture, once

1. Open **`/Applications/RedScreen.app`**. A shield icon appears in the menu bar; RedScreen has
   no Dock icon.
2. Click the shield, then **Capture Screenshot › Display**. macOS asks for Screen Recording
   permission.
3. Choose **Open System Settings**, then turn on **RedScreen** under **Privacy & Security ›
   Screen & System Audio Recording**.
4. Back in RedScreen, click **Quit & Reopen** in the banner. macOS applies the permission to the
   reopened app.

Capture now works. Try it on a window with some text, review the highlighted findings, then save
or copy the redacted image.

### 8. Update later

```bash
git pull
```

```bash
make install
```

Your permission and settings carry over. Always use the copy in `/Applications`: other copies,
such as one run from Xcode or from the build folder, are separate apps to macOS.

### If something goes wrong

| What you see | What to do |
| --- | --- |
| "Screen Recording is off" right after you allowed it | Click **Quit & Reopen**. macOS often applies a new permission only after the app restarts. |
| The banner says this copy is a development build or isn't signed | You are running a copy other than `/Applications/RedScreen.app`, or it was built without step 5. Quit it and open the installed copy. |
| `0 valid identities found` | Install the WWDR G3 certificate (step 4). |
| Build error "No signing certificate … found" | `Config/Local.xcconfig` has the wrong ID. Use the `OU` value from step 5, not the code in parentheses. |
| RedScreen isn't in the Screen Recording list | Click **Ask macOS Again** in the banner, or add `/Applications/RedScreen.app` with **+** in that list. |
| Still stuck | Quit RedScreen and reset its permission with the command below. Then open `/Applications/RedScreen.app` and repeat step 7. |

```bash
tccutil reset ScreenCapture com.georgeadadii.RedScreen
```

## Developing

The rest of this README is for working on RedScreen itself. The build needs no package
resolution or network access.

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

`make install` builds Release, signs it with the team in `Config/Local.xcconfig` (ad-hoc if
there is none), and replaces `/Applications/RedScreen.app`. See
[Set up RedScreen on your Mac](#set-up-redscreen-on-your-mac) for first-time signing and
permission setup, and [Keeping the permission](docs/CAPTURE_SHORTCUT.md#keeping-the-permission)
for how signing affects it. RedScreen is not notarized, so it is meant to be built by each user,
not downloaded.

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
the [Phase 1 readiness checklist](docs/PHASE1_READINESS.md). Issue #13 (RED-9) adds
[native region, window, and display capture](docs/SCREEN_CAPTURE.md) straight into the review flow,
with no screenshot file written. Issue #14 (RED-10) adds the app-menu Capture commands, an optional
[global capture shortcut](docs/CAPTURE_SHORTCUT.md) with conflict detection, Settings, and
Screen Recording permission guidance for every permission state. Issue #15 (RED-11) hardens the capture path
with end-to-end, stress, memory, and lifecycle tests, logs capture-to-review latency and memory as
numbers only, and records the [Phase 2 readiness checklist](docs/PHASE2_READINESS.md). Issue #16 (RED-12) adds the optional
[VS Code secret-hint extension](Extensions/vscode/README.md) and its authenticated, local-only
[hint protocol](docs/VSCODE_HINT_PROTOCOL.md). It sends rule IDs and keyed digests, never values or
document text. Issue #17 (RED-13) adds RedScreen's side: an opt-in, same-user listener in the
app's own container, and matching that lets fresh hints confirm, but never hide, findings in a
capture. Issue #18 (RED-14) adds [detection profiles](docs/DETECTION_PROFILES.md):
Balanced (the default, unchanged) and Conservative built-ins, plus validated user profiles with
thresholds, rule toggles, placeholder exclusions, and custom rules in a bounded pattern language.
Profiles can be imported and exported as plain-text settings, and anything that may hide findings
needs confirmation and stays visible during review.

