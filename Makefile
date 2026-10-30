PREFIX ?= $(HOME)/.local/bin
SWIFTC ?= swiftc
SWIFTFLAGS = -O

.PHONY: all build install clean uninstall install-terminalclip uninstall-terminalclip test-terminalclip

all: build

bin:
	mkdir -p bin

bin/menumeter: tools/menumeter/menumeter.swift | bin
	$(SWIFTC) $(SWIFTFLAGS) tools/menumeter/menumeter.swift -o bin/menumeter

bin/TerminalClip.app/Contents/MacOS/TerminalClip: tools/terminalclip/terminalclip.swift tools/terminalclip/Info.plist | bin
	mkdir -p bin/TerminalClip.app/Contents/MacOS
	$(SWIFTC) $(SWIFTFLAGS) -framework AppKit -framework ApplicationServices -framework Carbon tools/terminalclip/terminalclip.swift -o bin/TerminalClip.app/Contents/MacOS/TerminalClip
	cp tools/terminalclip/Info.plist bin/TerminalClip.app/Contents/Info.plist
	-codesign --force --sign - bin/TerminalClip.app

build: bin/menumeter bin/TerminalClip.app/Contents/MacOS/TerminalClip

install-terminalclip: bin/TerminalClip.app/Contents/MacOS/TerminalClip
	mkdir -p $(HOME)/.local/opt
	rm -rf $(HOME)/.local/opt/TerminalClip.app
	ditto bin/TerminalClip.app $(HOME)/.local/opt/TerminalClip.app
	@echo "✓ TerminalClip installed to $(HOME)/.local/opt/TerminalClip.app"

test-terminalclip: | bin
	$(SWIFTC) -D TERMINALCLIP_TEST tools/terminalclip/terminalclip.swift tools/terminalclip/tests/main.swift -o bin/terminalclip-tests
	./bin/terminalclip-tests
	@if [ "$(uname -s)" = Darwin ]; then $(SWIFTC) -typecheck -framework AppKit -framework ApplicationServices -framework Carbon tools/terminalclip/terminalclip.swift; fi

install: build
	mkdir -p $(PREFIX)
	install -m 755 bin/menumeter $(PREFIX)/menumeter
	cp tools/menumeter/menumeter.swift $(PREFIX)/menumeter.swift
	@echo "✓ MenuMeter installed to $(PREFIX)/menumeter"
	$(MAKE) install-terminalclip

uninstall-terminalclip:
	-pkill -x TerminalClip 2>/dev/null
	-launchctl bootout gui/$(id -u)/com.terminalclip.local >/dev/null 2>&1
	rm -f $(HOME)/Library/LaunchAgents/com.terminalclip.local.plist
	rm -rf $(HOME)/.local/opt/TerminalClip.app
	@echo "✓ TerminalClip removed (Zsh configuration left untouched)"

uninstall: uninstall-terminalclip
	pkill -x menumeter 2>/dev/null || true
	rm -f $(PREFIX)/menumeter
	rm -f $(PREFIX)/menumeter.swift
	rm -f $(HOME)/Library/LaunchAgents/com.user.menumeter.plist
	@echo "✓ MenuMeter uninstalled"

clean:
	rm -rf bin

