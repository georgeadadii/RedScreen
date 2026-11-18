# Developer secret detection

Issue #7 classifies likely developer secrets in OCR output. `ContextualSecretDetector`
(`RedScreenCore/Services/Detection`) is pure Swift. It reads `OCRObservation`s only, never image
data, and is independent of Vision and SwiftUI. It runs automatically after text recognition;
the document window footer shows "N likely secrets · M to review", and **Highlight Findings**
marks the affected lines (red: likely, orange: review).

## Output

Each `SecretDetection` carries:

- `evidence`: rule ID, confidence, and the IDs of the observations involved; no matched text is
  copied.
- `spans`: the **value's** UTF-16 range inside each observation, excluding its label, quotes, and
  separators. A wrapped value has one span per line. This lets #8 redact only the value where
  geometry allows.
- `family`, `severity`, and `assessment`:
  - `.likely` at confidence ≥ 0.7;
  - `.needsReview` at confidence ≥ 0.35;
  - anything lower is dropped.

  Ambiguous findings are always returned for review, never silently discarded.

Findings are stored in the session's `RedactionDocument.detections`
(`processingState = .secretsDetected`). They are cleared whenever observations are replaced, and
results for a replaced or closed document are discarded.

## Scoring

Most rules score `confidence = keyword weight × value strength`.

**Keyword weight** comes from the key or label. Keys are split on `_`, `-`, `.`, spaces and
camelCase, then `0/1/5/@` inside words are mapped back to `o/l/s/a` to undo OCR confusions:
- **Strong (1.0):**
  - `password`, `passwd`, `pwd`, `pass`, `passphrase`, `passcode`, `secret`, `credential(s)`,
    `apikey`, `privatekey`, `clientsecret`;
  - `<api|private|signing|secret|access|client|…>_key`;
  - `<access|refresh|auth|api|github|…>_token`.
- **Medium (0.75):** `token`, `key`, `auth`, `authorization`, `cookie`, `otp`.
- **Weak (0.65):** `salt`, `nonce`, `seed`, `id`, `identifier`, `signature`. These flag only
  random-looking values that mix letters and digits.
- **Excluded:** a final word naming metadata, such as `_TTL`, `_LENGTH`, `_URL`, `_ID`/`Id` (for
  non-random values), `_SHA`, `checksum`, `region`, `user` or `scopes`. Keys ending in `hint` are
  capped at review.

**Value strength** starts at 0.4 for values of at least 6 characters, then adds:
- **+0.2** for three or more character classes;
- **+0.2** for all four classes or entropy ≥ 3.5 bits/char;
- **+0.2** for length ≥ 16.

Some values are never secret: placeholders (`changeme`, `<password>`, `${VAR}`, `$VAR`,
`your-…-here`, `\(token)`), numbers, booleans, mostly masked values (`ghp_****…`) and URLs.
Partially masked values and UUIDs are capped at review.

Assignment confidence is capped at 0.95, so specific shapes (provider tokens, bearer, URLs) win
when findings overlap. Overlapping findings resolve to the most confident one, and output is
sorted in reading order.

Punctuation is normalized conservatively before matching, one UTF-16 unit for one, so offsets
still index the original text, which is never mutated:
- Unicode dashes become `-`;
- curly quotes become straight quotes;
- non-breaking spaces become spaces;
- full-width `:` and `=` become ASCII.

## Families

| Family | Severity | Rationale |
| --- | --- | --- |
| `envAssignment` | High | `.env` and shell exports are the most common place keys are pasted. |
| `credentialKeyword` | High | Config, code, tables and prose label secrets explicitly. |
| `bearerToken` | High | Bearer values are complete credentials by themselves. |
| `privateKey` | Critical | A private key compromises everything it signs or decrypts. |
| `connectionString` | High | A URL password grants direct database or cache access. |
| `providerKeyShape` | High | Vendor formats are recognisable without context. |
| `highEntropyContextual` | Medium | Random strings are common and usually benign; context is required. |

### `envAssignment`: `KEY=value` lines

- **Examples:**
  - `DATABASE_PASSWORD=RSFAKE-pg-7d1c9a42`
  - `export AWS_SECRET_ACCESS_KEY="wJalr…EXAMPLEKEY"` (value only, quotes excluded)
  - `API_KEY = RSFAKE-key-6b2d91` (spaces around the separator)
  - `PASSW0RD=…` (OCR digit in the key)
- **Review:** `TRACE_TOKEN=rsfake-ambig-01`, a generic `token` key with a modest value.
- **Counterexamples:** `NODE_ENV=production`, `PORT=3000`, `JWT_SECRET=changeme`,
  `API_KEY=your-api-key-here`, `GIT_SHA=<40 hex>`, `LOG_LEVEL=debug`.

### `credentialKeyword`: labelled secrets in config, code, tables and prose

- **Examples:**
  - `"apiKey": "RSFAKE-api-…"`
  - `db_password:   RSFAKE-yaml-pw-91`
  - `client_secret = 'RSFAKE-cs-…'`
  - `the new password is: RSFAKE-n3w.P@ss_77`
  - a `Secret access key` table label with the value in the next cell
- **Review:**
  - `"passwordHint": …`
  - `I reset it to 'RSFAKE-Temp!Pass#2026' but login fails.` (quoted value in password prose)
  - a `Staging secret` cell whose value is partially masked
- **Counterexamples:**
  - `let password = try keychain.read(…)`
  - `"tokenTTL": 3600`
  - `"clientId": "web-dashboard-client"`
  - `PASSWORD_MIN_LENGTH: "12"`
  - `Token: ghp_*****…`
  - `Please never share your password; …`
  - a `Publishable` label

### `bearerToken`

- **Examples:** `Authorization: Bearer RSFAKE-tok-…`, JWT-shaped bearer values, any casing or
  spacing.
- **Review:** truncated values (`Bearer RSFAKE-tr...` or a `…` suffix) and 8–15 character values.
- **Counterexamples:** `Bearer <token>`, `Bearer $DEPLOY_TOKEN`, `Bearer \(token)`.

### `privateKey`

- **Examples:** `-----BEGIN (RSA|EC|OPENSSH|…) PRIVATE KEY-----` through the END line. Every
  line of the block is included, and em-dash OCR errors in the armor are normalized.
- **Review:** `ENCRYPTED PRIVATE KEY` blocks, which still need a passphrase to use.
- **Counterexamples:** `BEGIN CERTIFICATE`, `BEGIN PUBLIC KEY`.

### `connectionString`

- **Examples:**
  - `postgres://app:RSFAKE-db-pw@host` (password only)
  - `redis://:pw@host` (empty username)
  - a URL whose password wraps onto the next line: the two lines are joined when the first ends
    inside the password and the next starts at the same left edge.
- **Review:** a username without a password (`mongodb://rsfake_reporter@host`).
- **Counterexamples:**
  - `postgres://localhost:5432/app`
  - `redis://127.0.0.1:6379`
  - `ssh://git@…`
  - passwords that are placeholders

### `providerKeyShape`

- **Formats:**
  - GitHub `gh[pousr]_` and `github_pat_`
  - GitLab `glpat-`
  - Slack `xox[abprs]-`
  - Stripe `sk_live_`/`rk_live_` (and `_test_` at 0.75)
  - Google `AIza…`
  - npm `npm_`
  - Anthropic `sk-ant-`
  - OpenAI-style `sk-…`
  - three-part JWTs
- **OCR tolerance:** `@` is accepted where `0` is expected.
- **AWS access key IDs:** an ID alone (`AKIA…`) is an identifier, so it goes to **review**. An ID
  exported as `…ACCESS_KEY_ID=` is likely.
- **Counterexamples:** publishable `pk_` keys, masked tokens.

### `highEntropyContextual`

- **Examples:**
  - `webhook signing secret 7Hq2RSFAKE…` (no separator)
  - `INTERNAL_ID=RSFAKE7f3a9c2e1b5d` and `deploy nonce rsfake…` (weak context: review)
- **Counterexamples:** UUIDs, commit SHAs and other hex-only strings, `sha256-`/`sha512-` integrity
  strings, SSH fingerprints, and random strings with no credential word nearby.

## Bounded work

The analysis is capped so a large screenshot cannot make it slow:
- at most 5,000 observations, and the first 2,048 UTF-16 units of each;
- private key blocks of at most 200 lines;
- bounded quantifiers in every regex, and no nested unbounded repetition.

The detector checks for cancellation every 256 lines. Tests cover 300 random malformed-Unicode
inputs, a 220,000-character line, and 6,000 observations.

## Privacy

Findings are never persisted or sent anywhere. Descriptions show the rule, family, assessment and
span count only. Diagnostics carry counts only:
- `sensitive_information_detected` counts likely findings;
- `detections_needing_review` counts findings to review;
- `secret_detection_failed` carries no payload.

## Precision and recall

Measured 2026-11-18 on the 14 synthetic scenarios (1x renderings) with
`SecretDetectorCorpusEvaluationTests`.

### Targets

| Input | Targets |
| --- | --- |
| Ground-truth text | sensitive recall = 100%, likely recall ≥ 90%, precision ≥ 90%, ambiguous surfaced ≥ 80%, no benign hits, value-only spans |
| Vision OCR | sensitive recall ≥ 85%, precision ≥ 85% |

### Results

| Input | Sensitive recall | Likely | Precision | Ambiguous surfaced | Benign hits |
| --- | --- | --- | --- | --- | --- |
| Ground-truth text | 22/22 (100%) | 22/22 | 33/33 (100%) | 11/11 | 0 |
| Vision OCR (end to end) | 22/22 (100%) | 22/22 | 33/33 (100%) | 11/11 | 0 |

**Read these numbers with care.** The rules were developed with this corpus in view, so 100% on
it shows coverage of the known scenarios, not generalization. The off-corpus table tests in
`SecretDetectorRuleTests` exercise variants not in the corpus:
- spacing and casing;
- OCR digit confusions in keys and tokens;
- runtime-built provider shapes;
- additional placeholders and benign shapes.

Issue #19 will add broader evaluation and release gates. Reports list fixture, span and rule IDs
only.
