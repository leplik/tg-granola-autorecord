APP_NAME := Telegram-Granola Autorecord
COMMAND := tg-granola-autorecord
AGENT_LABEL := pro.saac.tg-granola-autorecord.agent

.PHONY: build test app install uninstall icon release

build:
	swift build

test:
	swift test

# Ad-hoc signed bundle for local testing, in .build/app.
app:
	scripts/build-app.sh --sign - --arch native

install: app
	rm -rf "/Applications/$(APP_NAME).app"
	cp -R ".build/app/$(APP_NAME).app" /Applications/
	-launchctl kickstart -k "gui/$$(id -u)/$(AGENT_LABEL)" 2>/dev/null
	open "/Applications/$(APP_NAME).app"

uninstall:
	-"/Applications/$(APP_NAME).app/Contents/MacOS/$(COMMAND)" disable
	rm -rf "/Applications/$(APP_NAME).app"

icon:
	swift scripts/make-icon.swift

# Signed, notarized release from this Mac. See docs/releasing.md.
release:
	scripts/release.sh
