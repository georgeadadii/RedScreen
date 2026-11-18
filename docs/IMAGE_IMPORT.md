# Screenshot import

Issue #5 lets a user open or drop a screenshot and turns it into a validated, upright, in-memory
pixel buffer that becomes the active document.

## User flow

- **Import Screenshot…** in the menu bar popover (⌘O) opens the document window and a sandboxed
  Open panel limited to PNG, JPEG, and HEIC/HEIF.
- Dropping a file on the popover's import row or on the document window imports it. Exactly one
  file URL is accepted per drop.
- The document window shows the image upright and aspect-fit, sized with the core
  `AspectFitGeometry`, with its pixel dimensions in the footer.
- Errors appear in a banner with an actionable message that never includes the file name or
  location. A failed import leaves the open document untouched.
- **Close** (⌘W) or closing the window closes the document and clears every session artifact.

The window is created by AppKit on demand, so launching still opens no window. It opts out of
state restoration and window tabbing.

## Pipeline

`ImageIOImageImporter` (`RedScreenCore/Platform`) checks each condition before the next
allocation:

1. **File access.** It begins security-scoped access and requires a regular, non-empty file no
   larger than `maximumFileBytes`. It reads at most `limit + 1` bytes, so a file that grows after
   its size check is still rejected. It then closes the handle and ends access on every path,
   before decoding.
2. **Type.** The container is identified from its contents with ImageIO, not from the extension.
   Only `public.png`, `public.jpeg`, `public.heic`, and `public.heif` are accepted.
3. **Budget.** PNG dimensions are read straight from the IHDR chunk, and every format's
   dimensions from ImageIO's header parse. Images wider or taller than `maximumDimension`, or with
   more than `maximumPixelCount` pixels, are rejected before decoding. Width × height is
   overflow-checked.
4. **Integrity.** ImageIO decodes truncated files leniently and fills the missing rows with grey,
   so `ImageContainerValidator` rejects incomplete containers first:
   - **PNG:** every chunk must be in bounds with a valid CRC-32, and the file must contain IDAT and
     IEND.
   - **JPEG:** the file must start with SOI and have an EOI after the last start-of-scan.
   - **HEIC/HEIF:** the top-level ISO BMFF boxes must exactly span the file.
5. **Decode and normalize.** ImageIO's transform-applying decode is used at full size, so EXIF
   orientations 1–8 become upright pixels. The result is drawn into a tightly packed RGBA8
   (premultiplied) buffer:
   - Wide-gamut RGB sources stay in **Display P3**.
   - Everything else is converted to **sRGB**: sRGB itself, untagged, grayscale, indexed and CMYK
     sources.
   - Higher bit depths are reduced to 8 bits per component.

The importer returns `ImportedImage(sourceIdentity, pixelDimensions, pixels)`. The pixels carry a
`PixelBufferLayout`: dimensions, format and colour space. That layout and colour space are the only
metadata retained. The encoded file is discarded, so EXIF, GPS, maker notes, embedded thumbnails,
and file paths never reach the document, and an imported session's `sourceImage` is nil. ImageIO
caching is disabled and nothing is written to disk.

### Default limits (`ImageImportPolicy.standard`)

| Limit | Value |
| --- | --- |
| Encoded file size | 64 MB |
| Width or height | 16,384 px |
| Pixel count | 64 Mi px (≈ 67 MP), so the decoded buffer is at most 256 MB |

These limits comfortably exceed 6K Retina and multi-display screenshots.

## Replacement and stale results

`ScreenshotImportController` (`RedScreenCore/Services`, main actor) gives every import a
generation token:

- Starting another import cancels the previous task, and closing the document invalidates it. A
  result that arrives afterwards is discarded along with its pixels.
- Only a successful decode calls `SecureImageSessionLifecycle.createSession(importedImage:)`. That
  call clears the previous session before publishing the new one, and it rejects pixel layouts
  that disagree with the declared dimensions.
- Failures set `lastError` and log `import_rejected`. Successes log `image_imported`. Neither log
  event has a payload.
- The controller never holds pixels itself: `activePixels` reads through to the active session.

## Sandbox

The app adds `com.apple.security.files.user-selected.read-only`. Access is granted only to files
the user picks in the Open panel or drags in. RedScreen does not register recent documents or use
`NSDocument`, and it copies nothing into its container. AppKit may still remember the panel's last
folder, as it does for every app.

## Tests

- `ImageIOImageImporterTests` cover:
  - PNG, JPEG and HEIC, with type detection from contents;
  - alpha, Display P3 retention, and conversion of other colour models;
  - all eight EXIF orientations, checked against an independent implementation of the orientation
    definition;
  - every synthetic fixture at 1x and 2x;
  - empty, missing, directory, non-file, truncated (PNG, JPEG, HEIC), damaged, zero-sized and
    over-budget inputs;
  - security-scope release on every path, no file writes, and no retained metadata.
- `ScreenshotImportControllerTests` cover success, failure leaving the document untouched, stale
  results, close during import, cancellation, and drop validation.
- `ScreenshotImportUITests` drive the real app:
  - **Open panel:** imports a synthetic fixture and checks its dimensions and the rendered aspect
    ratio. A corrupt file then shows an error and keeps the document, and closing removes it.
  - **Finder drag-and-drop:** drags the same fixture from Finder onto the document window.
