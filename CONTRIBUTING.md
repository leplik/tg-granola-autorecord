# Contributing

Thanks for helping. Bug reports, fixes after Granola updates and documentation improvements are all welcome.

## Development setup

You need macOS 14.4 or later, Xcode 16 or later, and a Telegram client and Granola to try changes for real.

```sh
git clone https://github.com/leplik/tg-granola-autorecord.git
cd tg-granola-autorecord
swift test
```

Build and run a local copy of the app:

```sh
make app      # ad-hoc signed bundle in .build/app
make install  # copies it to /Applications and opens it
```

An ad-hoc signed build gets a new code signature on every build, so macOS asks for Accessibility access again after each `make install`. Remove the old entry in System Settings first. macOS may also not offer the notification prompt to a build that is not notarized; allow notifications for the app in System Settings instead.

## Layout

| Path | What it holds |
|---|---|
| `Sources/AutorecordCore` | Pure logic with no system calls: call detection, the state machine, the stop sequence and the agent loop. Everything here is covered by tests. |
| `Sources/tg-granola-autorecord` | The app and CLI: CoreAudio, deep links, the Unix socket, Accessibility, notifications, the login item. |
| `Tests/AutorecordCoreTests` | Unit tests, plus end-to-end agent scenarios that run against a fake clock, Telegram and Granola. |
| `scripts/` | Bundle build, icon and release scripts. |
| `docs/internals.md` | The Granola internals the app depends on, and how to re-check them. |

New behaviour belongs in `AutorecordCore` with a test. System integration code should stay thin.

## When a Granola update breaks something

1. Run `tg-granola-autorecord doctor` and `tg-granola-autorecord ax-dump` during a recording.
2. Follow `docs/internals.md` to find what changed.
3. Update the matcher or constants, add a test for the new shape, and bump `Granola.testedVersion`.

## Pull requests

- Keep changes focused, and explain the why in the description.
- `swift test` must pass. CI runs it on every pull request.
- If you touch detection, starting or stopping, check it on a real Telegram call and say so.
- Add a line under `Unreleased` in `CHANGELOG.md` for user-visible changes.

Releases are cut by the maintainer, see `docs/releasing.md`.
