# Native screen capture

Choose **Capture Screenshot** in the menu bar, **Capture** in the document window, or the
**Capture** menu in the app menu bar (Region ⌥⌘1, Window ⌥⌘2, Display ⌥⌘3), then pick **Region…**,
**Window…**, or **Display**. The optional [global shortcut](CAPTURE_SHORTCUT.md) starts a region
selection from any app. The captured pixels go straight into the Phase 1 review flow. No
screenshot file is written.

- **Region:** the document window hides, every display is dimmed, and a hint shows the modes.
  Drag a rectangle, then release to capture. Press Return (or D) to capture the whole display
  under the pointer, W to choose a window instead, or Escape (or right-click) to cancel. The
  overlay is live dimming only: nothing on screen is captured or kept to draw it.
- **Window:** pick an on-screen window of another app from a menu at the pointer. Window titles
  and app names appear only in that menu and are never stored or logged.
- **Display:** captures the only display directly. With several displays, it offers a menu of
  displays by number, size, and scale.

Capture follows the same path as an import. The open document is replaced only when a capture
succeeds. A newer import or capture supersedes an older one, and **Cancel** stops one in flight.
See [workflow](WORKFLOW.md).

## Architecture

- **RedScreenCore** defines the platform-neutral contract in `Domain/ScreenCapture.swift`:
  - `ScreenCaptureService` and `CaptureTarget`, which identifies a region, a window by number,
    or a display by number.
  - `CaptureError`, with fixed, non-identifying messages.
  - `CaptureGeometry`, the pure coordinate math.
- `CapturedImageNormalizer` draws the captured `CGImage` into the canonical RGBA8 buffer with the
  same normalization step as an import, and enforces the import pixel budget. A fully transparent
  window capture is reported as `protectedContent`.
- The **app target** holds everything that is specific to ScreenCaptureKit or permissions, in
  `RedScreen/Capture/`:
  - `ScreenCaptureKitService` uses `SCScreenshotManager` to capture a single frame. It holds no
    stream open, so nothing keeps running after a capture.
  - `RegionSelectionOverlay` draws the selection panels. A test checks that ScreenCaptureKit
    never appears in RedScreenCore.

## Coordinates and scale

Capture works in Core Graphics global points, with the origin at the top-left of the main
display, y increasing downward, and negative origins for displays above or to the left. The region
overlay converts AppKit's bottom-left coordinates with `CaptureGeometry.coreGraphicsRect`.

`CaptureGeometry.plan` picks the display holding the largest part of the region, and clips the
region to it. Displays can differ in scale and colour space, and a document holds one raster. It
then aligns the rectangle outward to whole device pixels at that display's backing scale, and
requests exactly that pixel size. Captures are therefore native resolution and sharp on 1x, 2x,
and mixed-scale setups. Window and display captures use ScreenCaptureKit's `pointPixelScale` and
`captureResolution = .best`. Wide-gamut displays are captured in Display P3, and everything else
in sRGB.

## Permission and privacy

- **Permission:** only Screen Recording permission is needed. It is requested only when the user
  starts a capture, at most once, and guidance is shown for each state. See
  [Capture shortcut and permission](CAPTURE_SHORTCUT.md#screen-recording-permission).
- **What is captured:** RedScreen's own windows are always excluded, and the selection panels set
  `sharingType = .none`. The cursor is not captured.
- **No disk or logs:** the frame is normalized in memory and handed to the session. The capture
  code contains no file or logging APIs, which a test checks. Logs record only `screen_captured`
  or `capture_failed`.

## Errors

| Case | Result |
| --- | --- |
| Escape, right-click, dismissed menu, or task canceled | Nothing changes and no message is shown. |
| Permission not granted | `permissionDenied`, with **Open System Settings** and **Check Again**. |
| Capture refused although access is granted, as a policy does | `permissionRestricted`, with no Settings link. |
| Window closed or display removed | `targetUnavailable` |
| Displays change during region selection | `displayConfigurationChanged` |
| Protected window, which returns no visible pixels | `protectedContent` |
| Click without dragging, or a region off every display | `emptyRegion` |
| Capture over the pixel budget | `tooLarge` |

With a document open, these appear as a banner and the document keeps its state. Without one, the
workflow is `failed(.captureFailed(...))`.

## Verification

`ScreenCaptureTests` covers:
- Coordinate flipping, negative display origins, 1x and 2x scales, fractional pixel alignment,
  regions spanning mixed-scale displays, edge clamping, and empty regions.
- Normalizer pixel order, colour space, protected content, and size limits.
- The controller with a fake service: success, canceled capture, permission denial and recovery,
  a disappeared target, a stale capture superseded by a newer import, canceling an in-flight
  capture, and file-system checks.
- Confining ScreenCaptureKit to the app target.

`Phase2CaptureIntegrationTests` covers each target kind through save and copy, rapid and
interleaved captures, memory release, and latency. See [Phase 2 readiness](PHASE2_READINESS.md),
which also has the multi-display, Spaces, full-screen, and permission-revocation matrix.

The region selection also ends when RedScreen is deactivated, the screens sleep, or the user
session switches.

Real capture needs Screen Recording permission, so it is verified manually:

| Case | 1x display | 2x display | Mixed 1x + 2x |
| --- | --- | --- | --- |
| Region inside one display: output size equals points × scale, sharp text | [ ] | [ ] | [ ] |
| Region across two displays: clipped to the larger part | | | [ ] |
| Window capture: correct size, no shadow, other windows not included | [ ] | [ ] | [ ] |
| Window on a secondary display | | | [ ] |
| Display capture: full native resolution, RedScreen's windows absent | [ ] | [ ] | [ ] |
| Escape during region selection keeps the open document | [ ] | [ ] | [ ] |
| Unplug or rearrange a display during selection: friendly error, document intact | | | [ ] |
| Protected content, such as a DRM video window: friendly error | [ ] | [ ] | |
| First capture without permission: prompt, then Open Settings, then retry works | [ ] | | |
| No new files in `~/Library/Containers/com.georgeadadi.RedScreen` after capturing | [ ] | | |
