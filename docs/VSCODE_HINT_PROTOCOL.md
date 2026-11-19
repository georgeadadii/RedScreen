# VS Code hint protocol, version 1

The optional [RedScreen Secret Hints](../Extensions/vscode/README.md) extension can tell RedScreen
which secrets are in the active editor. It sends no values, document text, file names, or paths.
RedScreen works the same without it, and Phase 1 and 2 behaviour doesn't depend on it.

RED-12 defined the protocol and built the extension. RED-13 implements the native side:
- `HintProtocol` and `HintBridgeServer` (the listener)
- `EditorHintStore` (matching)
- `EditorHintBridge` (lifecycle)

`Extensions/vscode/test/support/fakePeer.ts` remains the TypeScript reference server.
`test/fixtures/protocol-vectors.json` holds cross-language vectors that both implementations must
reproduce byte for byte (`npm test` and `HintProtocolVectorTests`).

## Goals and non-goals

- **Purpose:** improve precision. A hint confirms that a specific value RedScreen saw is a secret
  of a specific kind.
- **Never sent:** raw values, whole documents, workspace content, file names, or paths. A digest
  is useless without the session key.
- **No transport outside the machine:** a Unix domain socket only. There is no TCP, network
  entitlement, or cloud service.
- **Fail closed:** any version, authentication, sequence, freshness, size, or format problem ends
  the connection. RedScreen then carries on exactly as if the extension were absent.

## Pairing and endpoint

While **Settings › VS Code Hints** is on, RedScreen publishes a **pairing file** in a private
directory in its own sandbox container:
`~/Library/Containers/com.georgeadadii.RedScreen/Data/tmp/rsh/rendezvous.json`. The socket
`hints.sock` is beside it. The extension uses this path by default, and the
`redscreenHints.rendezvousFile` setting overrides it.

The container location needs **no extra entitlement**: the app keeps exactly sandbox plus
user-selected files. A shared app-group container was rejected, because it needs a provisioned
Developer team and an entitlement change. macOS may ask once whether VS Code may access data
from another app. Allow it to use hints, or deny it and nothing is shared. The directory path is
kept short, because Unix socket paths are limited to 103 bytes.

The file has this form:

```json
{"protocol":"redscreen-hints","version":1,"socket":"/abs/path/hints.sock",
 "session":"<16 random bytes, base64url>","key":"<32 random bytes, base64url>","expires":1767225600000}
```

| Rule | The extension refuses the file unless |
| --- | --- |
| File | It is a regular file (not a symlink), owned by the current user, mode `0600` or stricter, and at most 4 KiB. |
| Directory | The file's directory is owned by the user and is `0700`. |
| Socket | The socket is a socket owned by the user, in a `0700` directory owned by the user. |
| Contents | It has exactly these six fields, `version` is 1, `expires` is in the future, and the session and key have the stated lengths. |

- **Who can connect:** the file is the only way to learn the key, and the permissions limit it to
  the user's own processes. Both sides then prove they hold the key.
- **Session lifetime:** RedScreen deletes the file and rotates the session when hints are turned
  off, when it quits, or when `expires` passes. The extension reads the file only when the user
  runs **Connect to RedScreen**. It keeps the key in memory and zeroes it on disconnect.

## Keys

All keys are HMAC-SHA256 of the session key `K` under fixed labels, with no separators between
parts. `S` is the session ID, and `Nc` and `Ns` are the client and server nonces (16 random bytes
each).

| Key | Value |
| --- | --- |
| Server proof | `HMAC(K, "rs-hints-v1/server" ‖ S ‖ Nc ‖ Ns)` |
| Client proof | `HMAC(K, "rs-hints-v1/client" ‖ S ‖ Ns ‖ Nc)` |
| Client → server message key | `HMAC(K, "rs-hints-v1/conn/client-to-server" ‖ S ‖ Nc ‖ Ns)` |
| Server → client message key | `HMAC(K, "rs-hints-v1/conn/server-to-client" ‖ S ‖ Nc ‖ Ns)` |
| Digest key | `HMAC(K, "rs-hints-v1/digest" ‖ S)` |

The message keys are unique to each connection and direction, so messages can't be replayed
across connections or reflected back to their sender. The digest key is the same across
connections in a session, so RedScreen can match hints, and it changes with every session.

## Framing and handshake

Each frame is a 4-byte big-endian length followed by UTF-8 JSON, at most 16 KiB. A declared length
over the limit ends the connection before the payload is read. Every message has exactly the
fields listed for its type. `v` must be 1; any other number is reported as incompatible.

```
C → S  {"t":"hello","v":1,"session":S,"nonce":Nc}
S → C  {"t":"challenge","v":1,"nonce":Ns,"proof":serverProof}   client verifies: spoofed peers fail here
C → S  {"t":"auth","v":1,"proof":clientProof}                  server verifies
S → C  {"t":"ready","v":1,"seq":0,"mac":…}
```

After `ready`, every message carries:
- `seq`: per direction, starting at 0 on each connection. It must be exactly one more than the
  last, or the message is treated as a replay.
- `mac`: the base64url HMAC-SHA256, under that direction's message key, of the message's
  canonical JSON without `mac`. Canonical JSON sorts keys at every level, has no whitespace, and
  allows integers only.

## Messages after the handshake

| Message | Fields | Meaning |
| --- | --- | --- |
| `hints` (C → S) | `seq`, `sent`, `expires`, `doc`, `hints`, `mac` | Replaces the hints for document nonce `doc`. |
| `clear` (C → S) | `seq`, `doc`, `mac` | Withdraws the hints for `doc`. |
| `ack` (S → C) | `seq`, `accepted`, `mac` | The number of hints accepted. |

- **`hints` timing:** `sent` and `expires` are Unix milliseconds. `expires − sent` is at most
  30 s. A message is rejected when `expires` has passed, or when `sent` is more than 2 s in the
  future. RedScreen also drops stored hints once they expire.
- **`doc`:** 16 random bytes that the extension chooses for each open document, for this VS Code
  session. It is never derived from the file name or path.
- **`hints` list:** at most 64 entries, each exactly `{"rule","conf","digest"}`:
  - `rule`: a rule ID from the shared list. It is the same ID RedScreen's native detector uses,
    checked by `VSCodeHintRuleParityTests`. Unknown IDs are rejected.
  - `conf`: an integer from 0 to 100 (the native confidence × 100).
  - `digest`: `base64url(HMAC(digestKey, rule ‖ 0x00 ‖ normalize(value)))`.
- **`normalize`:**
  1. Apply NFKC.
  2. Split into lines.
  3. Trim each line and drop empty lines.
  4. Join with `\n`.
  5. Remove one pair of matching surrounding quotes.

  A private-key block is therefore its lines joined by `\n`, as RedScreen rebuilds it from its
  OCR lines.

**Rate limits:** the extension sends at most 4 messages a second, in bursts of up to 8. A rapid
scan replaces any unsent pending one. RedScreen should close a connection that exceeds
10 messages a second.

## How RedScreen uses a hint

**Matching.** After OCR and native detection of a **capture**, RedScreen rebuilds each finding's
value from its OCR spans. Spans on one line are concatenated, and lines are joined with `\n`.
RedScreen normalizes that value and computes its digest under the session's digest key. A hint
matches only when both `rule` and `digest` are equal. RedScreen never asks for or receives the
editor's value.

**Effect.** A match can only *confirm* a finding:
- It is recorded as an `EditorHintConfirmation` beside the native `DetectionEvidence`, which is
  left unchanged.
- If the hint's confidence is at least 80, a `needsReview` finding becomes `likely`. Likely
  findings are included for redaction by default.
- A lower-confidence hint only marks the finding.
- Nothing is ever lowered, excluded, or removed, and unmatched hints are ignored.
- Confirmed candidates show "Confirmed by VS Code hint" in review. They are still reviewed,
  edited, and rendered with solid pixels like any other candidate.
- Hints never authorize export: an unresolved candidate still blocks rendering.

**Expiry.** Hints are dropped when any of these happens:
- their `expires` passes (at most 30 s)
- their connection withdraws them (`clear`) or disconnects
- one capture has used them (capture completion)
- a screenshot is imported or the document closes
- the listener stops

The listener stops when hints are turned off, at quit, and when the Mac sleeps, the screens
lock, or the user session switches. That is how "app backgrounding" is handled: RedScreen is a
menu bar app that is usually in the background while you capture, so ordinary deactivation
does not count. Each start is a new session with a new key, so the extension must connect again.

**Imports.** Imported screenshots never use hints, because a file on disk may be from any time.

**Logs.** Only fixed events with counts are logged:
- `hint_bridge_started`
- `hint_bridge_stopped`
- `hint_peer_authenticated`
- `hint_peer_rejected`
- `editor_hints_confirmed`, whose count is the number of confirmed findings

Digests, values, document nonces, and payloads are never logged or stored.

## Native listener

- **Peers:** only same-user peers are accepted, checked with `getpeereid`. There are at most
  four connections, and a peer that hasn't authenticated within 3 s is disconnected.
- **Validation:** every message is checked as described above. The first violation closes the
  connection, and a rejection is logged as a count only.
- **Session lifetime:** a session lasts at most 8 hours, the pairing file's `expires`.
- **Stopping:** stopping removes the socket and pairing file and zeroes the session and
  connection keys held by the listener.

## Compatibility policy

- **Exact version.** Both sides speak exactly version 1. Any other version is refused
  (`incompatible`) in the pairing file or the handshake, and neither side falls back.
- **Additive changes need a new version.** That includes new message types, fields, or rule IDs.
  Both implementations, the vectors, and this document change in one pull request, and the
  vectors are regenerated with `npm run vectors`.
- **Rule IDs.** The rule-ID list is shared. `HintProtocolVectorTests` checks that the native list
  equals the extension's, and `VSCodeHintRuleParityTests` checks that both detectors agree on the
  parity fixture.
- **What users see.** An extension that is newer or older than the app reports "uses a different
  hint protocol version", and RedScreen behaves exactly as without the extension.

## Threat notes

| Threat | Mitigation |
| --- | --- |
| Another local user | Owner-only file and socket permissions. The extension checks them and refuses otherwise. |
| A process running as the same user | It can read the pairing file, as it could read the editor's files anyway. The protocol keeps values out of transit and logs, but doesn't defend against malware running as the user. |
| Spoofed RedScreen | It can't produce the server proof without `K`. The extension disconnects and sends nothing. |
| Spoofed extension | It can't produce the client proof without `K`, so the server refuses it. |
| Replay or reflection | Per-connection, per-direction keys, strict sequence numbers, and expiry. |
| Offline guessing of a digest | Not possible without `K`, which is never sent and lives only in memory and the short-lived pairing file. |
| Oversized messages and floods | A 16 KiB frame cap enforced before buffering, the hint count cap, and rate limits. |
