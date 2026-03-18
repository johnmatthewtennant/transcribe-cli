PREFIX ?= /usr/local

all: build

build:
	swift build -c release

install: build
	install -d $(PREFIX)/bin
	install .build/release/transcribe $(PREFIX)/bin/transcribe
	install -d $(PREFIX)/.agents/skills/transcribe-audio
	install -m 644 .agents/skills/transcribe-audio/SKILL.md $(PREFIX)/.agents/skills/transcribe-audio/SKILL.md
	install -m 644 .agents/skills/transcribe-audio/SETUP.md $(PREFIX)/.agents/skills/transcribe-audio/SETUP.md

uninstall:
	rm -f $(PREFIX)/bin/transcribe

clean:
	swift package clean

.PHONY: all build install uninstall clean
