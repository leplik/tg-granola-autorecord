# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.0.0] - 2026-09-16

### Added

- Background app that starts a Granola recording when a Telegram call begins and stops it when the call ends.
- Supports Telegram Desktop from telegram.org and the Mac App Store, and the native Telegram for macOS client.
- Notification with a **Stop Recording** button when a recording starts.
- Two stop routes: Granola's Meet extension socket when Granola allows it, then the stop button through Accessibility.
- Notifications when Granola is missing, a recording does not start, a recording cannot be stopped, or Granola stops a recording on its own.
- Leaves recordings it did not start alone, and does not restart a recording the user stopped.
- Resumes responsibility for its recording after a restart.
- `doctor`, `monitor`, `enable`, `disable`, `restart`, `start`, `stop` and `ax-dump` commands.
- Signed and notarized universal build, GitHub Releases and a Homebrew cask.

[Unreleased]: https://github.com/leplik/tg-granola-autorecord/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/leplik/tg-granola-autorecord/releases/tag/v1.0.0
