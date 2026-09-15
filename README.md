# granola-autorecord

[Granola](https://granola.ai) starts recording on its own for Zoom, Google Meet and Teams, but it does not notice Telegram calls. This small macOS background agent fills that gap. When Telegram opens the microphone and the speaker, it starts a Granola note. When the call goes quiet, it stops the recording.

> Not affiliated with Granola or Telegram. The agent relies on undocumented parts of the Granola desktop app, and any Granola update can break them. Every failure ends in a macOS notification, so a broken update means "stop it by hand", not a silent all-day recording.

## How it works

**Detecting a call.** Once a second the agent reads the list of audio processes from CoreAudio, available since macOS 14.4 and requiring no permission. A call has started when a watched app keeps both the microphone and the speaker open for 5 seconds. It is over when both stay closed for 20 seconds, so a reconnect does not split the note.

**Starting.** The agent opens `granola://new-document`. That is Granola's own deep link: it creates a note and starts transcribing. If Granola is already recording, for example during a Meet call, the agent leaves it alone.

**Stopping.** Granola has no stop command, so the agent tries three things in order. It only ever stops a recording it started, and it backs off if you stopped the recording yourself.

1. **Meet extension socket.** Granola listens on a local socket for its Google Meet extension. The agent sends the extension's `meeting-ended` event there. Granola acts on it only when its `meet_consent_extension_auto_stop` feature flag is on and the recording is at least three minutes old. The agent reads the flag from Granola's cache and skips this step when the flag is off.
2. **Stop button.** The agent finds the stop button in Granola's window through the Accessibility API and presses it. This needs the Accessibility permission.
3. **Notification.** If Granola is still recording, a notification asks you to stop it by hand.

## Requirements

- macOS 14.4 or later
- The Granola desktop app, signed in
- Swift 5.10 or later, from Xcode or the Command Line Tools

## Install

```sh
git clone https://github.com/leplik/granola-autorecord.git
cd granola-autorecord
make install
```

`make install` builds a release binary, copies it to `~/Library/Application Support/granola-autorecord/` and starts a LaunchAgent that runs at login.

Then open **System Settings → Privacy & Security → Accessibility** and enable `granola-autorecord`. Without it the agent still starts recordings, but the stop-button step is skipped.

macOS ties the Accessibility permission to the exact binary. After each `make install`, remove the old entry with the minus button and enable the new one.

## Checking that it works

Watch what the detector sees, without touching Granola:

```sh
make monitor
```

Place a Telegram call and look for `call signal: full`. Also record a voice message and see whether it reaches `full`; see limitations below.

Follow the agent itself:

```sh
tail -f ~/Library/Logs/granola-autorecord.log
```

Try each action by hand:

```sh
.build/release/granola-autorecord start    # starts a Granola note, as on call start
.build/release/granola-autorecord stop     # runs the stop sequence, as on call end
.build/release/granola-autorecord ax-dump  # lists the buttons Granola exposes to Accessibility
```

`stop` and `ax-dump` need Accessibility access for the terminal app you run them from.

## Configuration

Settings are optional. Create `~/.config/granola-autorecord/config.json` with any of these fields, then run `make install` again or restart the agent.

```json
{
  "apps": ["com.tdesktop.Telegram", "org.telegram.desktop", "ru.keepcoder.Telegram"],
  "startDelaySeconds": 5,
  "endGraceSeconds": 20,
  "creationSource": "application_menu"
}
```

| Field | Meaning |
|---|---|
| `apps` | Bundle identifiers to watch. The defaults cover Telegram Desktop from telegram.org, Telegram Desktop from the Mac App Store, and the native Telegram for macOS client. |
| `startDelaySeconds` | How long microphone and speaker must both stay open before recording starts. |
| `endGraceSeconds` | How long both must stay closed before the call counts as over. |
| `creationSource` | The `creation_source` value sent to Granola for new notes. |

To find another app's bundle identifier, run `osascript -e 'id of app "WhatsApp"'`.

## Limitations

- **Voice messages.** Recording a voice message opens the microphone. If the speaker is also open for more than five seconds, the agent takes it for a call. Check with `make monitor` and raise `startDelaySeconds` if needed.
- **Stop button matching.** Granola's stop button is an icon with a tooltip and has no accessible name. The agent recognises it by its CSS classes next to the transcript control, and presses nothing unless exactly one button matches. A Granola redesign can break this. When that happens, run `ax-dump` during a recording and open an issue with the output.
- **Socket side effects.** While connected, Granola briefly counts the agent as a Meet extension client in its own analytics.
- **Where notes go.** Notes land in your Granola account like any other note, with your workspace's default sharing. Check that before recording private calls.

## Uninstall

```sh
make uninstall
```

This stops the agent and removes the binary and the LaunchAgent. The log and config file stay. Remove the Accessibility entry by hand.

## License

MIT
