# Capture shortcut and permission

## Starting a capture

Every capture command works from the keyboard and with VoiceOver:

| Where | How |
| --- | --- |
| Menu bar item | **Capture Screenshot** › Region…, Window…, or Display. The popover's Settings… item is ⌘,. |
| App menu bar | **Capture** menu: Capture Region… ⌥⌘1, Capture Window… ⌥⌘2, Capture Display ⌥⌘3, Import Screenshot…. It appears while a RedScreen window is open, when RedScreen temporarily becomes a regular app. When the window closes, RedScreen goes back to being a menu bar utility. |
| Document window | **Capture** menu next to Import…. |
| Global shortcut | Off until you turn it on. When it is on, it starts a region selection from any app. |

During a region selection, a hint lists the modes. Drag to capture a region. Press Return (or D)
for the whole display under the pointer, W to choose a window from a menu, or Esc to cancel.
Return and W are the alternatives to dragging for keyboard and VoiceOver users. Window and display
choices are standard menus that VoiceOver reads.

## Global shortcut

Turn it on in **Settings › Capture Shortcut**. The documented default is **⌥⇧⌘R**. Nothing is
registered until you turn the toggle on or choose **Use Default**.

- **Change…** records the next key combination typed in the Settings window. Esc cancels. The
  combination must include Command, Control, or Option.
- **Turning it off** unregisters the shortcut immediately. It stays off after relaunch, and your
  last choice is kept for when you turn it back on.
- **Relaunch:** a shortcut you turned on is registered again at launch. If it is no longer free,
  Settings shows it as not active and explains why, and RedScreen does not take it.

### Conflicts

RedScreen never takes a combination that something else uses. It refuses the new combination,
shows the reason, and keeps your previous shortcut working:

| Conflict | Detected by |
| --- | --- |
| A macOS shortcut that is turned on, for example in Keyboard Shortcuts, and the built-in screenshot shortcuts ⇧⌘3, ⇧⌘4, ⇧⌘5, ⌃⇧⌘3, and ⌃⇧⌘4 | The system's symbolic hot key list, checked before registering. |
| Another app's exclusive global shortcut | Exclusive registration, which macOS refuses for a held combination. |

An app that watches keys with an event tap, or registers its shortcut non-exclusively, can't be
detected. If your shortcut doesn't respond, choose another one.

### Permissions

The shortcut uses Carbon's `RegisterEventHotKey`. It needs no Accessibility or Input Monitoring
permission and receives only presses of the registered combination. It never sees other typing.
Recording a new shortcut uses a local event monitor that sees only keys sent to RedScreen's own
Settings window. A test checks that no event taps, global monitors, or Accessibility APIs are used.

## Screen Recording permission

macOS only reports whether access is granted. RedScreen derives four states:

| State | Meaning | What RedScreen shows |
| --- | --- | --- |
| Not determined | RedScreen has never asked. | Starting a capture asks macOS once, and macOS shows its prompt. |
| Denied | RedScreen asked, and access is still off. | What is blocked, **Open System Settings** (the Screen & System Audio Recording pane), **Ask macOS Again**, and **Check Again**. Starting a capture doesn't prompt again. |
| Restricted | Access looks granted, but ScreenCaptureKit still refuses, as a management policy does. | An explanation that System Settings can't change this, and to ask an administrator. There is no Settings link. |
| Granted | Capture proceeds. | Nothing in the capture flow. Settings shows the state. |

- **When access is requested:** only from a capture the user starts, through the menu bar item, a
  menu command, or the shortcut. It is never requested at launch, from Settings, or from **Check
  Again**. The one exception is **Ask macOS Again**, which asks once per click. A test checks that
  only one file can request it.
- **After a reset:** if the permission is reset (`tccutil reset ScreenCapture`) or RedScreen is
  removed from the list, macOS adds it back only when RedScreen asks. **Ask macOS Again** does
  that. macOS shows its prompt only if it has no decision on record. You can also add the app
  with **+** in that pane.
- **Development builds:** see [Keeping the permission](#keeping-the-permission). If the
  running copy is ad-hoc signed or runs from a build folder, the guidance says so.
- **How a change is noticed:** RedScreen re-reads the state without prompting when it becomes
  active, when Settings opens, and on **Check Again**. macOS usually applies a newly granted
  permission only to a fresh process, so the denied guidance offers **Quit & Reopen**. That
  releases the global shortcut and the VS Code hint listener, starts a new instance, and quits
  this one.
- **No previews:** no guidance view shows a preview or thumbnail of the screen or of other windows.
- **What is stored:** `CapturePreferenceStore` keeps whether access was requested and the shortcut
  choice, among its allowlisted preferences. Nothing about the screen is stored.

## Keeping the permission

macOS records Screen Recording permission against an app's **code signature**:
- **Ad-hoc signed** (no developer certificate, "Sign to Run Locally"): the permission belongs
  to that exact binary, so every rebuild or reinstall loses it.
- **Signed with a team** (Apple Development or Developer ID): the permission follows the
  certificate and bundle ID, and survives rebuilds.

Several copies also share the name "RedScreen":
- the `make` build in `.build/DerivedData`
- Xcode's build in `~/Library/Developer/Xcode/DerivedData`
- the installed app

System Settings shows a single entry, but the permission belongs to whichever copy you allowed.

### One-time setup for a reliable copy

1. **Sign with your team.** In Xcode › Settings › Accounts, add your Apple ID; a free Personal
   Team works. Then copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and set
   `DEVELOPMENT_TEAM` to your **team ID**: the `OU` field of your certificate, *not* the code in
   parentheses in its name. To print the certificate's fields, run:

   ```bash
   security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject
   ```

   `Local.xcconfig` is git-ignored, and builds without it (CI, fresh clones) stay ad-hoc.
   - **0 valid identities:** if `security find-identity -v -p codesigning` reports that,
     your keychain is missing Apple's **WWDR G3** intermediate, which issues current development
     certificates. Install `AppleWWDRCAG3.cer` from https://www.apple.com/certificateauthority/
     into your login keychain.
   - **Debugger access:** Release builds drop the debugger-attach entitlement
     (`get-task-allow`) that development signing would otherwise add.
2. **Install one copy:** run `make install`. It builds Release, quits any running RedScreen,
   replaces `/Applications/RedScreen.app`, and prints how the copy is signed (`TeamIdentifier`).
3. **Grant it once:** open `/Applications/RedScreen.app`, start a capture, and allow it in System
   Settings › Privacy & Security › Screen & System Audio Recording. If the list shows a stale
   entry, remove it with **−** first, or add the installed app with **+**.
4. **Reopen:** choose **Quit & Reopen** in the banner.

Use the installed copy day to day. Development builds and test runs never replace it. With a
team it keeps its permission across reinstalls; without one, allow it again after each `make install`.

**Hardened runtime.** It is on in Release only when a team is set. Its library validation
requires the app and its embedded `RedScreenCore` framework to be signed by the same team, so an
ad-hoc Release build with it on cannot load its own framework and aborts at launch. Before this
change, that is what happened to every `make install`.

**Starting over.** Quit RedScreen, then run:

```bash
tccutil reset ScreenCapture com.georgeadadii.RedScreen
```

Open the installed copy again and allow it once.

## Verification

- `CapturePermissionModelTests`:
  - Every state, and that reading the state never prompts.
  - Prompting once from not determined.
  - No second prompt after denial, including after relaunch.
  - Recovery from denied to granted and back.
  - Restricted until **Check Again**.
  - Guidance for every state.
- `GlobalShortcutControllerTests`:
  - Nothing registered by default.
  - Enable, change, disable, and relaunch.
  - Conflicts with macOS and other apps, keeping the previous shortcut.
  - Combinations without a modifier.
  - Store persistence and the store's key allowlist.
  - The lower-privilege mechanism, and the single place that requests access.
- `CaptureCommandsUITests` runs against Debug-only fakes selected by launch arguments (see
  `UITestHooks.swift`; they are not compiled into Release):
  - The menu command captures a synthetic frame.
  - The app's Capture menu exists.
  - ⌥⌘1 opens the selection, and Esc cancels it while keeping the document.
  - Denied and restricted guidance.
  - Shortcut enable, conflict, and disable.

Manual accessibility check:

| Case | Result |
| --- | --- |
| VoiceOver: popover Capture menu, then Display. Window menu read aloud. | [ ] |
| VoiceOver: ⌥⌘1, hear the selection hint, then Return captures the display | [ ] |
| Keyboard only: ⌥⌘1, then W, then arrow keys and Return to pick a window | [ ] |
| Keyboard only: Settings ⌘,, Tab to the toggle, Space, Change…, type a shortcut | [ ] |
| Global shortcut from another app starts a selection, and Esc cancels | [ ] |
| A conflicting shortcut, such as one used by another app, shows a reason and the old one still works | [ ] |
| First capture with access not determined: one prompt, then guidance with no second prompt | [ ] |
