# Saving and copying redacted images

After every finding is included or excluded, choose **Preview Redacted Image**. The flattened
preview is the final review gate: **Save As…** (Shift-Command-S) and **Copy Redacted Image**
(Shift-Command-C) appear only while it is on screen, and they output that exact raster. An edit,
undo, new import, or close discards the preview, and the controller refuses a render from an older
review revision (`ImageExportError.reviewChanged`). No action saves, copies, drags, or shares the
source image.

## Output type

`ScreenshotImportController.renderReviewedImage()` returns a `FlattenedRedactedImage`. Only
RedScreenCore can create one, and only by rendering the current, fully reviewed document. It
records the session and review revision it came from. `ImageExporter` and `RedactedImageClipboard`
accept only this type, so source pixels cannot be passed to them.

## PNG encoding and metadata

`ScrubbedPNGEncoder` encodes PNG from the flattened raster with a properties dictionary built in
place (no thumbnail). It then rebuilds the file from an allowlist of chunks: `IHDR`, `PLTE`,
`IDAT`, `IEND`, `iCCP`, `sRGB`, `gAMA`, `cHRM`, and `pHYs`. Everything else is dropped. This
includes the `eXIf` chunk ImageIO adds on its own, text chunks, timestamps, and Apple's `iDOT`
decoding hint, whose offsets would be wrong after filtering. A malformed encoder result is
rejected. Import has already discarded the original container, so no EXIF, GPS, comments,
thumbnail, or filename can be inherited. The suggested save name is always
`Redacted Screenshot.png`. JPEG is not offered: its lossy encoding would change the reviewed
pixels, and it cannot store alpha.

## Atomic save

`AtomicFileImageExporter` encodes first. It then writes the PNG into a new item-replacement
directory on the destination's volume and moves it into place with one `rename`. Readers see the
old file or the complete new one, never a partial write. The Save panel asks before replacing a
file. Only after that confirmation is `ExportDestination.replacesExistingItem` set. Otherwise
`renamex_np(RENAME_EXCL)` refuses to overwrite, even if a file appears after the panel closes. The
staging directory is removed on success, failure, and cancellation. The staged file holds only the
encoded redacted output, never the source. The destination is not logged or retained. Logs record
only `redacted_image_saved` or `redacted_image_save_failed`. Saving requires the
`com.apple.security.files.user-selected.read-write` sandbox entitlement.

## Clipboard

`PasteboardImageWriter` writes one pasteboard item that declares only `public.png`, containing the
same scrubbed encoding. It writes no file URL, string, source representation, or custom type
carrying review data. macOS may also advertise TIFF translations to readers. Those are generated
on demand from that PNG. Encoding happens before the pasteboard is cleared, so a failed copy
leaves the previous clipboard untouched.

## Feedback

Success and failure messages are fixed strings mapped from `ImageExportError`. They never show a
path, filename, or system error text.

## Verification

`ImageExportTests` covers:
- PNG round trips in sRGB and Display P3, at small and large sizes.
- The chunk allowlist, absence of EXIF, GPS, IPTC, TIFF, and text metadata, a single image with no
  thumbnail, and rejection of malformed PNG.
- Saves: a new file, refusal to replace without confirmation, a file created after the existence
  check, confirmed atomic replacement, encoding failure, an unwritable directory, a missing parent
  directory, and cancellation before and after staging. Every case checks that no partial file and
  no staging copy remain.
- Pasteboard types, decoded pixel content, and that a failed copy keeps the previous clipboard.

Controller tests check that only the current reviewed render can be saved or copied. The review UI
test copies and saves through the real sandboxed app and Save panel. It then checks the
pasteboard's declared type, the redacted pixels, the generic file name, and that the saved file
matches the copied bytes.
