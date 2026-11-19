# RedScreen Secret Hints for VS Code

An optional companion to RedScreen. When you ask it to, it finds secrets in the **active editor**
and tells RedScreen on this Mac which kinds of secrets are there. RedScreen uses the hints to
confirm what it detects in screenshots of your editor. RedScreen works fully without this
extension.

## What it does and doesn't do

- **Off by default.** It activates only when you run one of its commands. Opening files does
  nothing.
- **Only the active editor.** It never scans the workspace, other open files, or files on disk.
  Files over 1,000,000 characters are skipped.
- **Nothing leaves your Mac.** Hints go to RedScreen over a private Unix socket, after both sides
  prove they hold a session key from RedScreen's pairing file. It uses no network.
- **No values or text are sent.** A hint is a rule ID, a confidence, and a keyed digest. Values,
  document text, file names, and paths never leave the editor.
- **Nothing is recorded.** It has no output channel and no stored state, and it reports usage
  nowhere. Messages show counts only.
- **Fails closed.** If RedScreen isn't running, uses another protocol version, or can't
  authenticate, the extension disconnects and sends nothing.

## Getting connected

1. In RedScreen, turn on **Settings › VS Code Hints**.
2. In VS Code, run **RedScreen Hints: Connect to RedScreen**. macOS may ask once whether VS Code
   may access data from other apps. Allow it to use hints.
3. Run **Turn On Hints for the Active Editor**, or **Scan Active Editor Once**, then capture.

RedScreen uses fresh hints only for the next capture, and only to confirm findings it already
made. Sleeping, locking, or quitting RedScreen ends the session, so connect again afterwards.

## Commands

Run these from the Command Palette, under **RedScreen Hints**:

| Command | Effect |
| --- | --- |
| Scan Active Editor Once | Scans now. Sends hints if connected, otherwise only reports a count. |
| Turn On Hints for the Active Editor | Rescans the active editor shortly after you stop typing, and when you switch editors. |
| Turn Off Hints | Stops scanning and withdraws every hint already sent. |
| Connect to RedScreen / Disconnect from RedScreen | Opens or closes the authenticated connection. |
| Show Status | Shows whether hints are on and whether you're connected. The status bar item opens this too. |

## Settings

| Setting | Default | Notes |
| --- | --- | --- |
| `redscreenHints.rendezvousFile` | (empty: RedScreen's default) | The path of RedScreen's pairing file, read only when you connect. By default it is in RedScreen's container: `~/Library/Containers/com.georgeadadii.RedScreen/Data/tmp/rsh/rendezvous.json`. |
| `redscreenHints.debounceMilliseconds` | 500 | How long after you stop typing to rescan, while hints are on. |

## Detection

The rules use the same IDs as RedScreen's native detector:
- provider token shapes
- private-key blocks
- passwords in connection strings
- bearer tokens
- secret-named assignments in env, JSON, YAML, and code

Placeholders such as `changeme`, `${VAR}`, and `<your-token>`, and masked values, are ignored.
`test/fixtures/rule-parity.json` is checked against both detectors.

## Development

```bash
npm ci
npm test                  # compile, then unit, protocol, and package tests (node:test)
npm run test:integration  # runs the extension in VS Code against a fake RedScreen peer
```

The integration suite uses the VS Code install in `/Applications` or `VSCODE_EXECUTABLE`. If
neither exists, `@vscode/test-electron` downloads VS Code. The protocol is specified in
[docs/VSCODE_HINT_PROTOCOL.md](../../docs/VSCODE_HINT_PROTOCOL.md).
