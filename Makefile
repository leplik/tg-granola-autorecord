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
	@for i in $$(seq 50); do pgrep -f "/Applications/$(APP_NAME).app/Contents/MacOS/$(COMMAND)$$" >/dev/null || break; sleep 0.1; done
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
