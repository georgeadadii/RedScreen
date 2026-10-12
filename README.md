# RedScreen

RedScreen is a privacy-first native macOS menu bar utility for permanently redacting sensitive
information from screenshots. Processing is designed to remain entirely on the Mac.

This repository currently contains the Phase 1 foundation: a compact SwiftUI menu bar interface,
a testable core module, dependency-injection interfaces for the future processing pipeline, and
automated unit and UI smoke tests. Screenshot capture, importing, and processing are intentionally
not implemented yet.

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

RedScreen appears as a shield icon in the macOS menu bar. It intentionally has no main window and,
because it is configured as an `LSUIElement` agent application, it does not appear in the Dock.
Closing the popover leaves the utility running.

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

## Architecture

```text
RedScreen/
├── App/                    # MenuBarExtra entry point and application actions
└── UI/                     # Compact menu bar popover presentation
RedScreenCore/
├── Domain/                 # Framework-independent pipeline value types
└── Services/               # Replaceable capability protocols
    ├── ImageImporting
    ├── TextRecognizing
    ├── SensitiveInformationDetecting
    ├── RedactionRendering
    └── ImageExporting
RedScreenCoreTests/         # Core tests without launching SwiftUI
RedScreenUITests/           # Launch and empty-state UI tests
```

The app target depends on `RedScreenCore`; the core module does not depend on SwiftUI. Future
platform implementations can be injected behind the service protocols, while tests can use small
test doubles. This initial phase deliberately provides no production implementation of those
capabilities.

The application scene is a window-style SwiftUI `MenuBarExtra`, not a `WindowGroup`. Its compact
content is isolated in `MenuBarContentView`. A later issue can expand this popover or have the app
composition layer present a temporary floating review panel without coupling that UI to the core
pipeline or introducing a permanent main window.

## Privacy and security

- All future screenshot processing is intended to happen locally.
- The app sandbox is enabled with no additional entitlements.
- No network client, analytics, telemetry, crash-upload, cloud SDK, or third-party dependency is
  present.
- Sensitive image bytes, OCR text, file paths, detected values, and clipboard contents must never
  be logged.
- File access will be granted only through explicit user interaction in a later phase.

## Current status

Issue #1 establishes the application and architecture. The menu bar popover includes disabled
Capture Screenshot and Import Screenshot actions, a disabled Settings placeholder, About, and Quit
RedScreen. Image import, OCR, sensitive-information detection, redaction rendering, screenshot
capture, settings, and image export remain out of scope until later issues.

