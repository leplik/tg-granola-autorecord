APP_NAME := Telegram-Granola Autorecord
COMMAND := tg-granola-autorecord

.PHONY: build test app install uninstall icon release

build:
	swift build

test:
	swift test

# Ad-hoc signed bundle for local testing, in .build/app.
app:
	scripts/build-app.sh --sign - --arch native

install: app
	-pkill -TERM -f "/Applications/$(APP_NAME).app/Contents/MacOS/$(COMMAND)$$"
	rm -rf "/Applications/$(APP_NAME).app"
	cp -R ".build/app/$(APP_NAME).app" /Applications/
	open "/Applications/$(APP_NAME).app"

uninstall:
	-"/Applications/$(APP_NAME).app/Contents/MacOS/$(COMMAND)" disable
	rm -rf "/Applications/$(APP_NAME).app"

icon:
	swift scripts/make-icon.swift

# Signed, notarized release from this Mac. See docs/releasing.md.
release:
	scripts/release.sh
