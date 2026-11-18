# Solid-pixel redaction rendering

`SolidFillRedactionRenderer` implements `RedactionRenderer` over `DecodedPixels`. Pass the
session's orientation-normalized `decodedPixels` and its matching `RedactionDocument`.
The renderer requires a layout and rejects dimension mismatches before touching any bytes.

`RedactionRenderPlan` includes every region of included and manual candidates. Pending and
excluded candidates do not contribute fills. Minimum edges round down and maximum edges round
up, clamped to the physical image bounds. Coordinates use the canonical top-left pixel grid;
Retina display scale is not applied a second time. Overlaps and duplicate fills are harmless.

The renderer copies the source using `Data` copy-on-write and writes RGBA components directly
into each covered pixel. Alpha is always 255. No interpolation, antialiasing, compositing,
resizing, drawing context, vector layer, or removable annotation is involved. Every byte outside
the fills stays unchanged, including its alpha. A pending or excluded region overlapping an
included region is still covered by that included region.

## Colour handling

The output keeps the source `PixelBufferLayout`: tightly packed RGBA8 premultiplied-last pixels
in sRGB or Display P3. `RedactionFillColor` accepts three native-space 8-bit components. They are
already encoded in the destination's named space and are written exactly, without conversion.
A caller starting with a UI colour in another colour space must convert it to the source's
named space and quantize to 8-bit RGB before constructing the fill colour. The default black
is `(0, 0, 0, 255)` in either space. Opaque alpha means RGB needs no premultiplication adjustment.

## Ownership and privacy

The source is immutable. The returned `DecodedPixels` contains only the flattened raster and
non-sensitive dimensions, format, and colour-space metadata. It holds no document, OCR text,
provenance, encoded source, or annotations. Rendering creates no intermediate files and logs
nothing. The single working buffer becomes the result; temporary references are released at
return or failure. Cancellation is checked before rendering, each filled row, and before
returning, so a cancelled operation cannot return a partial result. As with the existing image
lifecycle, release is best effort; Swift `Data` does not promise cryptographic memory erasure.

Review/controller integration and export encoding are separate issues. An exporter must encode
this returned raster rather than the original source. The renderer does not change the session
or its review state.

## Verification

`SolidFillRedactionRendererTests` checks complete small rasters at 1x and 2x, fractional and
edge-touching fills, overlaps, every region of a multi-region candidate, included/manual parity,
pending/excluded preservation, hidden RGB and alpha replacement, custom exact colours in both
supported spaces, source immutability, deterministic bytes, invalid inputs, and cancellation.
The bundled `env-file-light-2x` import test checks every filled pixel against opaque black and
every unfilled pixel against the source, proving the secret-coloured pattern is gone.

Run `make test` for the full suite, or run only the core tests with:

```sh
xcodebuild -project RedScreen.xcodeproj -scheme RedScreen \
  -destination 'platform=macOS' -derivedDataPath .build/DerivedData \
  -only-testing:RedScreenCoreTests test
```
