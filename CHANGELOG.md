# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.0.1] - 2026-11-16

### Fixed

- Recordings stop again when a call ends. Once another assistive app has touched Granola, Granola keeps a basic accessibility tree in which its stop button ignores presses while the window is in the background, and the app pressed it anyway. Now the app presses the button only when it accepts presses. If needed, it shows Granola for about a second and then returns you to the app you were using.
- The stop button match no longer picks Resume, Start now or Retry, which take the same place in Granola's transcript pill.

### Changed

- `ax-dump` lists the actions of each button, so it shows whether the stop button accepts presses.
- Checked against Granola 7.786.3.

## [1.0.0] - 2026-09-16

### Added

- Login item app that starts a Granola recording when a Telegram call begins and stops it when the call ends.
- Setup checklist when the app is opened, with shortcuts to Accessibility, Notifications and Login Items settings, and a Turn Off button.
- Supports Telegram Desktop from telegram.org and the Mac App Store, and the native Telegram for macOS client.
- Notification with a **Stop Recording** button when a recording starts.
- Two stop routes: Granola's Meet extension socket when Granola allows it, then the stop button through Accessibility.
- Notifications when Granola is missing, a recording does not start, a recording cannot be stopped, or Granola stops a recording on its own.
- Leaves recordings it did not start alone, and does not restart a recording the user stopped.
- Keeps track of its recording through microphone dropouts, a consent pause in Granola, and a slow start of up to three minutes.
- Resumes responsibility for its recording after a restart, if the previous run was alive within two minutes.
- `doctor`, `monitor`, `enable`, `disable`, `restart`, `start`, `stop`, `test-notification` and `ax-dump` commands.
- Signed and notarized universal build, GitHub Releases and a Homebrew cask.

[Unreleased]: https://github.com/leplik/tg-granola-autorecord/compare/v1.0.1...HEAD
[1.0.1]: https://github.com/leplik/tg-granola-autorecord/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/leplik/tg-granola-autorecord/releases/tag/v1.0.0
