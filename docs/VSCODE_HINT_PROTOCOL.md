# VS Code hint protocol, version 1

The optional [RedScreen Secret Hints](../Extensions/vscode/README.md) extension can tell RedScreen
which secrets are in the active editor. It sends no values, document text, file names, or paths.
RedScreen works the same without it, and Phase 1 and 2 behaviour doesn't depend on it.

RED-12 defines the protocol and builds the extension. The reference server is
`Extensions/vscode/test/support/fakePeer.ts`. RedScreen's own listener, and matching hints
against OCR text, are RED-13.

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

While the user has hints turned on in RedScreen, it publishes a **pairing file**. The default
location is provisional and is settled in RED-13; the `redscreenHints.rendezvousFile` setting
overrides it:

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

## How RedScreen uses a hint (RED-13)

For each native candidate, RedScreen computes the digest of its OCR value under each live
session's digest key, and looks for a hint with the same `rule` and `digest`. A match can raise
confidence or confirm the finding. A missing hint never lowers confidence and never hides a
native finding. Without hints, every Phase 1 and 2 result is unchanged.

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
