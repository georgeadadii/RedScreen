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
- **Development builds:** an ad-hoc signed ("Sign to Run Locally") build is identified by its
  exact binary, so each rebuild needs the permission granted again. Sign with an Apple
  Development team to keep it across rebuilds.
- **How a change is noticed:** RedScreen re-reads the state without prompting when it becomes
  active, when Settings opens, and on **Check Again**. A change made in System Settings is picked
  up when you return. macOS may ask you to reopen RedScreen first.
- **No previews:** no guidance view shows a preview or thumbnail of the screen or of other windows.
- **What is stored:** `CapturePreferenceStore` keeps whether access was requested and the shortcut
  choice. Nothing else is stored.

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
