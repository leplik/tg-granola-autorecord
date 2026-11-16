# Granola internals this app relies on

Granola has no public API for starting or stopping a recording. This app uses four undocumented parts of the Granola desktop app. Each can change in any Granola update, so this page records what each one is, where it was found, and how to check it again.

Checked against Granola **7.786.3** (Electron 45.2.3, Chromium 156). That version is stored as `Granola.testedVersion`, and `doctor` warns when a newer Granola is installed.

## How to inspect a Granola build

Granola is an Electron app. Its JavaScript ships in `app.asar`:

```sh
npx @electron/asar extract /Applications/Granola.app/Contents/Resources/app.asar /tmp/granola
```

The main process is `dist-electron/main/index.js`. The renderer chunks are in `dist-app/assets/`. The code is minified, so search for the string literals quoted below.

## 1. Starting: the `new-document` deep link

`granola://new-document?creation_source=application_menu` creates a note and starts transcribing. Transcription is skipped only when `auto_transcribe=0` is passed.

- **Where:** the URL parser whitelists hosts in an array that contains `` `new-document` ``. The renderer route reads `r.get('auto_transcribe')==='0'`.
- **Check:** `open -g "granola://new-document?creation_source=application_menu"` should start a recording within a few seconds.
- **`creation_source`:** values Granola itself uses include `application_menu`, `tray` and `session_timeout_toolbar`.

## 2. Detecting a recording: the microphone

Granola holds the microphone only while it transcribes. The app treats any process whose bundle identifier starts with `com.granola.app`, or whose executable lives in `Granola.app`, as Granola.

Granola also releases the microphone for a few seconds when its audio process restarts or the input device changes, for example when a Bluetooth headset switches profile. Mid-call, the app counts Granola as stopped only after 15 seconds off the microphone. Before calling a recording already stopped at the end of a call, it watches for 5 seconds.

- **Check:** `tg-granola-autorecord monitor` shows `Granola recording: yes` during a recording and `no` otherwise.

## 3. Stopping, route 1: the Meet extension socket

Granola's Google Meet extension reports meeting state over a Unix socket at `/tmp/granola-meet-consent-<hash>.sock`. The hash is the first 12 hex characters of the SHA-256 of the home directory path. The app writes one line:

```json
{"event":"meeting-ended","payload":{"meetingCode":null,"observedAt":1700000000000},"timestamp":1700000000000,"type":"granola:event"}
```

Granola acts on it only when both hold:

- the feature flag `meet_consent_extension_auto_stop` is `true` in `~/Library/Application Support/Granola/local-state.json`;
- the system-audio transcript is at least three minutes old.

- **Where:** search the main process for `` `meeting-ended` `` and the renderer for `meet-consent-extension-auto-stop-disabled`.

## 4. Stopping, route 2: the stop button

The stop button in the note view is icon-only. Its "Stop transcript" text is a hover tooltip, so it has no accessible name. The app finds it structurally:

- It sets `AXManualAccessibility` on Granola, which makes Electron build its web accessibility tree.
- It looks for an `AXButton` whose `AXDOMClassList` contains `min-w-10`, `pr-[3px]` and `pl-0`, next to a sibling with `min-w-[48px]`, which is the transcript pill with the waveform.
- The button must have no name. Resume, Start now and Retry take the same place in the pill and have the same classes, but they show text.
- It presses only when exactly one button matches. An explicit "Stop transcript" or "Stop transcribing" label wins if Granola ever adds one.

- **Where:** the renderer component with `` "data-testid":`stop-transcript-button` ``.
- **Check:** start a recording, then run `tg-granola-autorecord ax-dump`. The matching button is marked with `=>`, and `actions` shows whether it accepts presses.

### When Granola ignores the press

Chromium serves Granola's page in one of two accessibility modes. Only the complete mode accepts a press:

| Mode | When Chromium uses it | The stop button |
|---|---|---|
| Basic | An assistive app asks Granola for its role. Electron then keeps this mode until Granola quits. | Is in the tree with its classes, but has no `AXPress`. `AXUIElementPerformAction` reports success and nothing happens. |
| Complete | 2 s after `AXManualAccessibility` is set, but only for a page whose window is on screen. | Lists `AXPress`. A press stops the recording. |

A window behind other windows keeps the basic mode, because Chromium applies a new mode only to a page that is shown. Before 1.0.1 the app found the button in the basic tree at once and pressed it there, so the press did nothing.

The app now presses only a button that lists `AXPress`:

1. If the button has no `AXPress`, the app waits up to 3 s for Electron. This is enough when Granola's window is on screen.
2. If the button still has no `AXPress`, the app opens Granola, which shows the window, and waits up to 6 s.
3. After the press, the app gives the focus back to the app that was in front. It does not do this if the user switched apps meanwhile.

- **Where:** Electron's `enableScreenReaderCompleteModeAfterDelay:` and `accessibilityRole` in `shell/browser/mac/electron_application.mm`. Chromium's `internalAccessibilityActionNames` in `ui/accessibility/platform/browser_accessibility_cocoa.mm`, `AXObject::Serialize` in `third_party/blink/renderer/modules/accessibility/ax_object.cc` (the default action is sent only with `kExtendedProperties`), and `ApplyAccessibilityModeToWebContents` in `content/browser/accessibility/browser_accessibility_state_impl.cc`.
- **Check:** with a recording and Granola's window behind other windows, `ax-dump` prints a line that the match has no `AXPress` yet. `tg-granola-autorecord stop` should then log "showing Granola" and stop the recording.

## Things Granola does on its own

- **Workspace consent policy.** Granola evaluates "in-person meeting" rules when a recognised call app such as Chrome or Zoom releases the microphone during a recording. If the workspace requires consent, it stops the recording after three seconds. Telegram is not a recognised call app, so a Telegram call can look like an in-person meeting. The app never works around this. It notifies the user instead.
- **Inactivity auto-stop.** Some accounts have `inactivity_auto_stop` enabled, which stops recordings after a period without speech.
