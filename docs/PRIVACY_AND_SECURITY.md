# Privacy boundaries and secure image lifecycle

RedScreen treats every screenshot and every value derived from it as sensitive. Processing is
local to the sandboxed macOS application. The current app has no networking, telemetry, cloud
service, third-party dependency, or background crash-upload integration.

## Threat model

The protected assets are imported image bytes and filenames, decoded pixels, OCR observations,
candidate secret strings and their locations, preview and undo data, clipboard contents, and
exported images and destinations. Metadata such as file URLs, filenames, dimensions, and counts
can also disclose information; only deliberately selected, non-sensitive counts may cross the log
boundary.

Trust boundaries exist at user-selected input files, framework and process memory, AppKit and
macOS caches, the system pasteboard, explicit export destinations, unified logging and diagnostic
data, and the application sandbox. A future importer may read a user-selected file but must pass
its bytes directly into the in-memory session. A future exporter may write only a rendered,
redacted result to a destination explicitly selected by the user.

Likely failures include accidentally autosaving an original image or OCR output; putting
unredacted data in a temporary file, recent-items list, log, crash report, preview cache, or
pasteboard; retaining one document's state after opening another; applying an asynchronous OCR or
detection result to the wrong document; exporting source pixels instead of rendered pixels; or
introducing a network-capable dependency.

Mitigations are an application-sandbox entitlement with no network entitlement, no network or
telemetry code, a single in-memory lifecycle owner, clearing every session-owned artifact on close
or replacement, session-ID checks for asynchronous stage results, no lifecycle file-I/O API,
closed-enum logging with counts only, no recent-document registration, and explicit user action for
future clipboard or export operations. Tests enforce the lifecycle, logging boundary, and lack of
application-managed temporary source copies.

## Security invariants

Later import, OCR, detection, rendering, clipboard, and export work must preserve these rules:

1. Source images, decoded pixels, OCR text, detected candidate values, previews, clipboard-ready
   images, and undo history live only in the active `SecureImageSession` unless the user performs an
   explicit export or copy action.
2. Creating a replacement session clears the old session before publishing the new one. Closing a
   document clears the active session and releases the lifecycle's reference to it. Results tagged
   with an inactive session ID are rejected.
3. There is no autosave or implicit persistence of source pixels, OCR observations, detected
   values, previews, or undo state. RedScreen does not register source files as recent documents.
4. Import-to-export processing must not create an application-managed plaintext temporary image.
   Decode and render in memory; write only the final redacted result to a user-selected destination.
5. Production logs contain a predefined `PrivacyLogEvent` and a non-sensitive unsigned count only.
   OCR strings, candidate values, filenames, file URLs, clipboard contents, image bytes, and error
   descriptions never enter the logging API.
6. Processing remains on device. Do not add network entitlements, clients, telemetry, remote crash
   upload, cloud services, or network-capable dependencies.
7. Copy and export are explicit user actions. Do not place unredacted pixels or detected text on the
   pasteboard. Do not retain export destinations after the operation ends.

`ImageLifecyclePolicy` mirrors the policy choices that can be expressed in code. It is not a
substitute for design review when adding a new processing component.

## Operating-system limitations

Clearing a Swift reference is lifecycle control, not guaranteed secure erasure. Swift, AppKit,
Core Graphics, Vision, the allocator, virtual memory, compressed memory, swap, GPU surfaces, and
framework caches may retain copies for an unspecified time. RedScreen cannot synchronously find or
overwrite all such copies, and it makes no secure-memory-erasure guarantee.

APFS copy-on-write behavior, SSD wear levelling, snapshots, backups, indexing, and filesystem
caches also make overwrite claims unreliable. The design therefore prevents unnecessary plaintext
writes instead of attempting best-effort overwrite.

The macOS pasteboard is shared and may be read, cached, synchronized, or retained by the operating
system or other applications. RedScreen can minimize exposure by copying only a redacted image on
explicit request and may later offer best-effort pasteboard expiration, but it cannot guarantee
removal from every consumer or device.

Crash reports and diagnostic tools can capture memory, metadata, or execution context. RedScreen
does not intentionally attach sensitive state or upload crash data. Users and developers should
avoid submitting diagnostic artifacts produced while a sensitive document is open without first
reviewing them.
