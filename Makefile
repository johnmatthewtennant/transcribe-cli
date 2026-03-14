PREFIX ?= /usr/local

all: build

build:
	swift build -c release

install: build
	install -d $(PREFIX)/bin
	install .build/release/transcribe $(PREFIX)/bin/transcribe

uninstall:
	rm -f $(PREFIX)/bin/transcribe

clean:
	swift package clean

.PHONY: all build install uninstall clean
