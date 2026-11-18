# Synthetic screenshot fixtures

RedScreen's OCR, detection, composition, rendering, and evaluation work is tested against a
generated corpus of synthetic developer screenshots. **Every credential-like value in the corpus is
fake.** No fixture is a capture of a real terminal, account, dashboard, or environment file.

## Layout

```text
RedScreenCoreTests/
├── Fixtures/                      # Generated corpus, bundled into the test target as a folder
│   ├── manifest.json              # Fixture IDs, file paths, and SHA-256 of every file
│   ├── images/<id>.png            # Rendered screenshot (sRGB, 1x and 2x)
│   └── ground-truth/<id>.json     # Machine-readable ground truth for the image
└── FixtureSupport/
    ├── FixtureSchema.swift        # Ground-truth schema (shared with the generator)
    ├── FixtureScenarios.swift     # Scenario specifications: text, labels, theme, layout
    ├── FixtureRenderer.swift      # Deterministic Core Text renderer and layout
    ├── FixtureLibrary.swift       # Loads the bundled corpus; bridges to core geometry
    ├── FixtureGeometryMatching.swift  # IoU, coverage, and FP/FN/geometry reports
    └── SyntheticValuePolicy.swift # Allowlist that proves fixture values are synthetic
Tools/FixtureGenerator/
├── main.swift                     # Writes the corpus to an explicit output directory
└── generator.sb                   # Sandbox profile used by `make fixtures`
```

Fixture IDs are `<scenario>-<scale>x`, for example `terminal-wrapped-url-dark-2x`.

The `editor-env-vscode-dark`, `editor-env-monaco-light` and `terminal-couriernew-dark` scenarios
reproduce real editor and terminal conditions found in user testing:
- a line-number gutter and syntax colours;
- tight line spacing;
- quoted values containing spaces;
- adjacent secrets;
- a pooled database URL with a password.

They use synthetic values and reserved hosts only. Scenarios can set a font (PostScript name and
size) and a line-height factor, and runs can carry a syntax colour role (`key`, `string`,
`comment`, `lineNumber`).

## Scenarios

The 17 scenarios are each rendered at 1x and 2x (34 fixtures). Together they cover:

| Dimension | Values |
| --- | --- |
| Category | `.env` files, terminals, JSON config, YAML config, CI logs, dashboards, benign code |
| Theme | light, dark, low contrast |
| Font | monospace (Menlo 12–13 pt, Monaco 11 pt, Courier New 13 pt), proportional (Helvetica 14 pt) |
| Difficulty | wrapped values, multiple columns, punctuation, nearby benign values, quoted values, multi-line blocks, editor chrome (line numbers, syntax colours, tight spacing), adjacent secrets |

Each detector family from issue #7 (`envAssignment`, `credentialKeyword`, `bearerToken`,
`privateKeyHeader`, `connectionString`, `providerKeyShape`, `highEntropyContextual`) has at least
one sensitive, one benign, and one ambiguous example. Benign examples include UUIDs, commit SHAs,
package integrity hashes, ports, public client IDs, placeholders, masked tokens, variable
references, and credential-free localhost URLs. `benign-code-light` and `benign-terminal-dark`
contain no redaction targets at all.

## Ground truth

Ground-truth JSON uses normalized coordinates with a **top-left origin** (`coordinateSpace:
normalized-top-left`). Values are rounded to 1e-6, so a span ending at a line's end may exceed its
box by up to 2e-6. Convert with `FixtureRect.normalizedRect()` and
`FixtureRect.imageRect(in:)`, which use the core `NormalizedRect`/`ImageRect` conversions with
`sourceOrigin: .topLeft`.

- `textBoxes` — one per rendered line or table cell: ID, exact text, and the typographic box
  of its visible text (ascent to descent, first to last non-whitespace glyph; leading indentation
  stays in `text` but not in the box). This is the OCR-level ground truth.
- `spans` — labelled values with a detector `family`, an `expectation`, a short `note`, and one
  `segment` per text box the value occupies. Segments carry UTF-16 offsets into the box text and
  the value's own rectangle. Labels exclude surrounding keys, quotes, and separators so the
  value-only redaction required by issue #7 can be checked.
- `expectation` is `sensitive` (must be redacted), `benign` (looks credential-like but must stay
  visible), or `ambiguous` (should be reviewable; never scored as a hit or a miss).

The scenario `description` is the human-readable summary of each fixture.

## Comparing pipeline output

```swift
let truth = try FixtureLibrary.bundled().fixture(id: "ci-log-dark-2x").groundTruth
let detections = try candidates.map {
    try FixtureDetection(imageRect: $0.region.rect, dimensions: truth.pixelDimensions())
}
let report = try FixtureGroundTruthComparator(tolerance: .init(minimumIoU: 0.5))
    .compare(detections, against: truth)
XCTAssertTrue(report.isClean, report.description)
```

Detections are matched one-to-one with span segments by descending IoU (ties broken by detection
index, then segment order). The report lists:

- **true positives**: sensitive segments localised at or above the IoU tolerance;
- **false positives**: detections on benign spans, duplicate detections, or stray regions;
- **false negatives**: sensitive segments with no detection;
- **geometry mismatches**: sensitive segments found below the IoU tolerance;
- **family mismatches**: correct localisations with a different detector family (these make
  `isClean` false; detections without a family are not penalised);
- **ambiguous matches**: reported, never scored.

`FixtureGeometry.coverageFraction(of:by:)` measures exact pixel coverage of a target by a set of
rectangles, for the complete-coverage checks in issues #8 and #9. Reports and policy violations
contain fixture, span, and text-box identifiers only, never fixture text, so they are safe in CI
logs.

## Synthetic-value policy

`SyntheticValuePolicyTests` enforces these rules across the whole corpus:

1. Every sensitive and ambiguous value contains a reserved marker: `RSFAKE`, `rsfake`, or
   `EXAMPLE`. `EXAMPLE` covers only AWS's published documentation keys (`AKIAIOSFODNN7EXAMPLE`,
   `AKIAI44QH8DHBEXAMPLE`, `wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY`).
2. Any provider-token shape, bearer value, URL with an embedded password, or JWT contains a
   marker, even when it is labelled benign.
3. Private-key armor only appears beside marked key bodies.
4. Email domains and URL hosts are reserved: `localhost`, `*.test`, `*.example`, `*.invalid`,
   `*.localhost`, `example.com`, `example.org`, `example.net`.
5. IPv4 addresses are loopback, `0.0.0.0`, or RFC 5737 documentation ranges.
6. No `/Users/` or `/home/` paths, and not the user name or full name of the account running
   the tests.

The policy has its own self-tests that confirm realistic unmarked values are rejected. Test
sources assemble those values at runtime so the repository contains no credential-shaped
literals outside the corpus.

## Regenerating

```sh
make fixtures
```

This compiles `Tools/FixtureGenerator/main.swift` with the schema, scenario, and renderer sources,
removes `RedScreenCoreTests/Fixtures`, and runs the generator with an empty environment
(`env -i`) under `Tools/FixtureGenerator/generator.sb`. The sandbox denies network access, denies
reading file contents anywhere under `$HOME` (including the repository and user-installed fonts),
denies launching other processes, and permits writes only to the fixture directory and the
system's per-user cache area. The generator's inputs are its compiled-in scenarios and the
output-directory argument. `SyntheticValuePolicyTests` checks that the generator sources use no
environment, home-directory, file-reading, networking, pasteboard, or screen-capture APIs and that
the Makefile and profile keep these restrictions.

Rendering is deterministic on a given machine: regeneration produces byte-identical PNGs and
JSON. Font rasterisation can differ between macOS releases, so tests treat the committed files
as the source of truth:

- `testCommittedFilesMatchManifestHashes` catches accidental edits to committed files.
- `testCommittedGroundTruthMatchesScenarioSpecifications` re-lays out every scenario in memory
  and requires identical text and labels, with geometry within 0.003. It fails if a scenario is
  changed without regenerating.
- `testTextBoxesContainRenderedInk` checks that every ground-truth box covers rendered text.

Commit regenerated fixtures in the same change as the scenario edit.

## Adding a scenario

1. Add a `FixtureScenario` to `FixtureScenarios.swift` and to `FixtureScenarios.all`. Use only
   marked values and reserved hosts. Never paste values from a real file, terminal, or account.
2. Run `make fixtures`, then `make test`.
3. Review the rendered PNGs and the ground-truth JSON diff by hand.

## Manual review record

- **2026-11-18, issue #4:** Reviewed all 28 rendered images and every text box. Every
  credential-like value carries a reserved marker or is an AWS documentation example. All hosts
  are reserved or loopback, every address is loopback or RFC 5737, and the only email domains are
  `example.com` and `example.org`. The corpus contains no personal names, real account
  identifiers, or home-directory paths. The commit SHAs are public identifiers from this
  repository's own history.
