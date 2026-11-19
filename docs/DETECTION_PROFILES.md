# Detection profiles

A detection profile tunes what RedScreen finds without weakening review invisibly. Choose one in
**Settings › Detection Profile**. Profiles hold **settings only**:
- confidence thresholds
- which built-in rules are on
- placeholder values to ignore
- custom rules

They never contain screenshots, recognized text, found values, or history. That makes them safe
to read, diff, and share as plain text.

## Built-in profiles

| Profile | Redact automatically from | Show for review from | Trade-off |
| --- | --- | --- | --- |
| **Balanced** (default) | 70% | 35% | Exactly the Phase 1 detector: fewer false positives, and a few weak findings are left for you to decide. |
| **Conservative** | 55% | 25% | Higher recall: more borderline values are covered or shown, at the cost of more false positives to exclude by hand. |

Golden tests on the synthetic corpus check two properties of the built-in profiles:
- Balanced produces exactly the native detector's findings.
- Conservative keeps every Balanced finding, and every Balanced finding that was redacted
  automatically is still redacted automatically.

## File format (version 1)

```json
{
  "format" : "redscreen-detection-profile",
  "version" : 1,
  "name" : "Team",
  "thresholds" : { "likely" : 70, "review" : 35 },
  "disabledRules" : [ "provider.stripe-test-key" ],
  "placeholders" : [ "team-placeholder-token" ],
  "customRules" : [
    { "id" : "custom.team-token", "kind" : "token", "prefix" : "team_",
      "characters" : "alphanumeric", "minLength" : 24, "maxLength" : 48, "confidence" : 90 },
    { "id" : "custom.vault-pass", "kind" : "keyValue", "keys" : [ "VAULT_PASS" ],
      "minLength" : 8, "maxLength" : 128, "confidence" : 85 }
  ]
}
```

- **Writing:** RedScreen writes profiles with sorted keys, so exports are stable and easy to
  compare.
- **Unknown fields:** rejected, which keeps a profile from silently carrying anything else.
- **Versions:** `version` is required. A file from a newer RedScreen fails with "made by a newer
  RedScreen. Update RedScreen to use it." Older versions are upgraded one step at a time in
  `DetectionProfileCodec.migrate`. Version 1 is the first version, so there is no migration step
  yet, and each new version must add one, with round-trip tests.
- **Size:** at most 64 KB, 64 custom rules, and 256 placeholders.

## Custom rules: a constrained pattern language

Custom rules are **not regular expressions**. RedScreen matches them with a linear-time scanner,
so a rule cannot backtrack, run code, or read files or environment variables. Each observation
is scanned up to the detector's per-line limit. A test runs 100,000-character adversarial input
in well under half a second.

| Kind | Matches | Fields |
| --- | --- | --- |
| `token` | A prefix at a word boundary, followed by characters from one set | `prefix` (3–32 letters, digits, `_`, `.`, or `-`), `characters`, `minLength` and `maxLength` (of the part after the prefix) |
| `keyValue` | The value after `KEY=` or `KEY:` (quotes allowed) for any listed key, matched whole and case-insensitively | `keys` (1–16 names), `minLength` and `maxLength` (of the value) |

- **`characters`** is one of `alphanumeric`, `alphanumericDashUnderscore`, `hex`, `digits`, or
  `tokenCharacters` (letters, digits, `-`, `_`, `.`, `+`, `/`, `=`).
- **Length:** at least 8, at most 512. A token longer than `maxLength` is a different shape, so
  it isn't matched.
- **Confidence:** 1–100, and at least the profile's review threshold.
- **IDs:** each rule's `id` is `custom.` plus a lowercase slug, and is shown on every candidate it
  produces ("Custom rule").
- **Overlaps:** where a custom finding overlaps a native one, the native finding wins, so built-in
  provenance is kept.

## Validation

Every problem is reported with a message that says what to change. Nothing invalid is ever
partly applied. Rejected profiles include:
- an empty or built-in name
- thresholds outside 1–100, or a review threshold above the redact threshold
- unknown built-in rule IDs
- short, long, or duplicate placeholders
- malformed, duplicate, or built-in custom rule IDs
- prefixes that are too short to be safe
- token rules that conflict, with the same prefix and characters
- lengths out of range
- confidences that could never show a finding

Imported files are validated before they open in the editor, and stored profiles are validated
again at launch: an invalid stored profile is skipped and reported.

## Settings that may expose content

Compared with Balanced, a profile **reduces coverage** if it does any of these:
- raises either threshold
- turns off a built-in rule
- lists placeholders

Selecting or saving such a profile needs **deliberate confirmation**: an alert lists exactly what
may be hidden, and the safe choice is the default. Settings keeps a warning on screen while the
profile is in use.

During review, the status bar shows **Profile: name · N hidden**. Its tooltip breaks the hidden
count down into rules turned off, placeholders, and the threshold. The detector runs at the
default review threshold or lower, so findings a profile hides are counted, never dropped
silently. Custom rules and lower thresholds only add findings.

## Changing profile

Choosing a profile re-evaluates the open document from its existing OCR text:
- OCR does not run again.
- The result is deterministic.
- Manual rectangles are kept exactly, with the same IDs.
- Generated candidates are recomputed, so their earlier review decisions and the undo history
  reset.
- The export gate still requires every pending candidate to be resolved.

## Storage and sharing

- **Stored with:** your own profiles are stored as plain-text profile JSON in RedScreen's
  preferences, under `detection.profiles`, with the selection in `detection.selectedProfile`.
  These are part of the five allowlisted keys of `CapturePreferenceStore`.
- **Import:** reads one `.json` you choose and opens it in the editor for review. It isn't saved
  until you save it.
- **Export:** writes only the selected profile's settings to a file you choose.
- **Placeholders are typed, not copied:** RedScreen never fills a profile from the open
  document. The editor asks you to type documented placeholders only, and never real values.

## Tests

| Suite | Covers |
| --- | --- |
| `DetectionProfileTests` | Round-trip and stability, plain-text keys, version and malformed-file messages, every validation rule, the token and key/value matcher with boundaries and placeholders, adversarial input timing, golden checks for the built-in profiles on the corpus, exclusion counts, and the library (save, select, persist, invalid stored profiles, rename, delete, import and export). |
| `DetectionProfileReevaluationTests` | A profile change re-evaluates the open document deterministically and keeps manual rectangles, and switching back to Balanced restores the native findings. |
| `CaptureCommandsUITests` | The confirmation alert for a reducing profile, and that cancelling keeps the current profile. Re-evaluation of an open document with a manual rectangle. |
