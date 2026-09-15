BIN := .build/release/granola-autorecord

.PHONY: build test install uninstall monitor

build:
	swift build -c release

test:
	swift test

install: build
	$(BIN) install

uninstall: build
	$(BIN) uninstall

monitor: build
	$(BIN) monitor
