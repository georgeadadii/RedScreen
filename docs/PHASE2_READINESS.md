# Phase 2 readiness checklist

Status of Phase 2 against its correctness, privacy, performance, and compatibility gates. Phase 2
covers native capture, capture commands, the global shortcut, and permission guidance. Recorded
on 2026-11-19 for RED-11 (GitHub #15). Phase 1 gates are in [Phase 1 readiness](PHASE1_READINESS.md)
and still apply.

## Environment

- **CI:** as in Phase 1. The GitHub `macos-26` runner with Xcode 26.6 runs `make build` and
  `make test-core`. Capture tests use injected frames, so CI needs no Screen Recording permission.
- **Local baseline machine:** Apple M4, 16 GB, macOS 26.6.2, built-in 3024×1964 Retina display,
  Debug configuration.
- **UI tests:** `make test` runs them, in a logged-in desktop session. They use the Debug-only
  fakes in `UITestHooks.swift`, so they capture no real screen content.

## Acceptance criteria

| Criterion | Status | Evidence |
| --- | --- | --- |
| Region, window, and display capture each complete the redaction and export flow | Pass (injected frames) | `testRegionWindowAndDisplayCapturesCompleteRedactionSaveAndCopy` runs each target kind through the production OCR, detection, composition, rendering, scrubbed PNG save, and pasteboard copy. Every secret's ink is opaque black in the saved and copied output. `testRegionDragAndReturnEachOpenANewCapture` drives the real overlay. |
| Rapid repeated capture does not crash or leak earlier session state | Pass | `testRapidRepeatedCapturesOpenOnlyTheNewestFrame`: 25 back-to-back captures finishing out of order, ignoring cancellation. Only the newest opens, and no stale result creates a session. |
| Cancellation and session replacement | Pass | `testInterleavedCaptureImportCancelAndCloseNeverLeakEarlierSessions` runs 120 seeded steps mixing capture, import, cancel, failure, and close. Every replaced session's pixels are cleared, and every session is released after close. |
| App deactivation | Pass | The selection ends on ⌘-Tab, screen sleep, or a user switch (`testDeactivationEndsTheSelectionAndKeepsTheDocument`). Quitting clears the open session. |
| Display disconnect | Automated in part | Changing the display configuration during selection reports `displayConfigurationChanged`. A target missing at capture time reports `targetUnavailable` or `displayConfigurationChanged`. Physical unplugging is in the manual matrix. |
| Permission changes | Pass, plus manual | `CapturePermissionModelTests` covers recovery from denied to granted and back, and restriction. A revoke caught by ScreenCaptureKit's preflight becomes `permissionDenied`, and the guidance refreshes. Revoking in System Settings while RedScreen runs is in the manual matrix. |
| No app-managed unredacted file, thumbnail, or recent item | Pass | The end-to-end run inventories temporary, cache, and application-support directories. It finds no new image or secret text, and nothing registers recent documents (source scan). |
| Capture-to-review baselines and supported configurations documented | Pass | Below. |
| Phase 1 import behaviour unchanged | Pass | Every Phase 1 test passes unchanged. `testImportLogsNoCaptureMeasurements` confirms that imports log no capture events. |

## Performance baselines

`ScreenshotImportController` measures capture-to-review latency in production and logs it as
`capture_to_review_duration_ms`. That is the time from starting the capture service until the
captured document is reviewable, after OCR, detection, and composition. At the same moment it
logs `memory_footprint_mb`, the process's physical footprint. Both are numbers only. Imports log
neither.

Single runs from `Phase2CaptureIntegrationTests` on the baseline machine:

| Measurement | Result |
| --- | --- |
| Capture to review, `terminal-wrapped-url-dark-1x` (400×172) | 112–243 ms. Normalization takes about 3 ms. |
| Capture to review, `editor-env-vscode-dark-2x` (1800×658) | 200–225 ms. Normalization takes about 5 ms. |
| Footprint when reviewable (test process) | 80–118 MiB |
| 20 consecutive 4K (3840×2160, about 32 MiB) captures | Peak about 47 MiB above baseline, the same after close. Retaining 8 frames as a control adds about 190 MiB, so the measurement detects real retention. |

OCR dominates, as in Phase 1. Real ScreenCaptureKit capture time isn't included above, because
it needs permission. Measure it with the manual matrix. CI ceilings are 2 s to capture and 25 s
to review.

## Configuration audit

| Area | Finding |
| --- | --- |
| Entitlements | Exactly `app-sandbox` and `files.user-selected.read-write`, enforced by test. Screen Recording is a TCC permission and needs no entitlement. There is no network, camera, microphone, or Apple Events access. |
| Permission strings | None. macOS has no usage-description key for Screen Recording and uses its own prompt text. The project declares no `*UsageDescription` keys (test). Accessibility and Input Monitoring are never requested. |
| Capture scope | `SCScreenshotManager` captures one frame per request. There is no `SCStream`, so nothing keeps capturing when idle (test). The cursor and RedScreen's own windows are excluded. |
| Overlay | It dims the live screen only, sets `sharingType = .none`, and draws no screenshot. |
| Pasteboard | Only after the user chooses Copy: one item, `public.png`, holding the flattened redacted render. See [export](IMAGE_EXPORT.md). |
| Lifecycle | No window is created at launch. The document window opts out of state restoration. The app becomes regular only while that window is open. Closing it or quitting clears the session. The Settings window holds controls only. |
| Persistence | Only `CapturePreferenceStore`: whether access was requested, and the shortcut choice (see [capture shortcut](CAPTURE_SHORTCUT.md)). |
| Logging | The closed `PrivacyLogEvent` enum with numeric counts. Phase 2 adds `screen_captured`, `capture_failed`, `capture_to_review_duration_ms`, and `memory_footprint_mb`. |

## Outside RedScreen's control

RedScreen doesn't write unredacted pixels to disk, but it can't control the operating system.
It doesn't claim secure deletion:

- **Memory:** pixels live in process memory until the session closes. macOS may compress or page
  memory to its encrypted swap. Clearing a buffer doesn't overwrite physical pages the system has
  already copied.
- **Clipboard:** Copy places the *redacted* PNG on the general pasteboard. macOS Universal
  Clipboard can send it to your nearby devices, and clipboard-history utilities may keep it.
- **Saved files:** a saved redacted PNG is an ordinary file. Spotlight, Time Machine, iCloud Drive,
  or other sync tools may index or copy it, depending on where you save it.
- **Other capture tools:** the macOS Screenshot tool, other screen recorders, and screen sharing
  are independent of RedScreen. RedScreen's overlay is hidden from capture, but the screen
  content underneath isn't.
- **System indicators and logs:** macOS may show its Screen Recording indicator and record that
  RedScreen used the permission. That record never includes RedScreen's capture content.

## Supported configurations

macOS 14 or later, the deployment target. Tested on Apple silicon with macOS 26.6. Any
combination of 1x and 2x displays is supported, along with displays at negative origins, P3 and
sRGB displays, and Spaces and full-screen apps. A region spanning displays is clipped to the
display holding most of it (see [screen capture](SCREEN_CAPTURE.md)).

## Manual compatibility matrix

Run with real Screen Recording permission on a Release build. Record the date, macOS version, and
hardware.

| Case | Expected | Result |
| --- | --- | --- |
| Region on built-in Retina, then save and copy | Output at native pixels; secrets redacted in the saved and copied PNG | [ ] |
| Region on an external 1x display | Sharp output at the 1x size | [ ] |
| Region across built-in 2x and external 1x | Clipped to the larger part | [ ] |
| Window capture of a window on a secondary display | Correct window, no shadow | [ ] |
| Display capture of each display | Native resolution; RedScreen's windows absent | [ ] |
| Capture over a full-screen app (global shortcut from inside it) | The overlay appears over the full-screen Space; the region is captured | [ ] |
| Capture on a non-primary Space | The overlay joins the current Space; window list shows that Space's windows | [ ] |
| Unplug a display during region selection | Friendly error; document intact | [ ] |
| Unplug the chosen display between selection and capture | `targetUnavailable` or `displayConfigurationChanged` | [ ] |
| Close the chosen window before capture | `targetUnavailable` | [ ] |
| ⌘-Tab away during region selection | Selection ends; nothing captured | [ ] |
| Lock the screen or sleep during selection | Selection ends | [ ] |
| Revoke Screen Recording in System Settings while RedScreen is running, then capture | Denied guidance; no crash; no prompt | [ ] |
| Grant again, return to RedScreen, Check Again | Granted; capture works (macOS may require relaunch) | [ ] |
| Hold the global shortcut down, or press it rapidly | One selection at a time; no duplicate documents | [ ] |
| After a session: `~/Library/Containers/com.georgeadadi.RedScreen` | No new image or text files; only the preferences plist | [ ] |
| After a session: Finder › Recent, the Dock menu, and File › Open Recent | No RedScreen entries | [ ] |
| Activity Monitor during 10 captures | Memory returns near its starting level after closing | [ ] |
