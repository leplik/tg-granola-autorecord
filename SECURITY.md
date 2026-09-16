# Security policy

## Supported versions

Only the latest release receives fixes.

## Reporting a vulnerability

Please report privately through GitHub: open the repository's **Security** tab and choose **Report a vulnerability**. Do not open a public issue.

You can expect a first reply within a week. Once a fix is released, the advisory is published with credit, unless you prefer to stay anonymous.

## Scope

The agent runs as your user, reads process audio state from CoreAudio, opens Granola deep links, writes to Granola's local Unix socket, and presses a button in Granola through the Accessibility API. It makes no network requests of its own. Reports about any of these paths are welcome.
