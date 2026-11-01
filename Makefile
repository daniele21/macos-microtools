PREFIX ?= $(HOME)/.local/bin
SWIFTC ?= swiftc
SWIFTFLAGS = -O

.PHONY: all build install clean uninstall install-terminalclip refresh-terminalclip uninstall-terminalclip test-terminalclip build-runnerpulse install-runnerpulse refresh-runnerpulse test-runnerpulse uninstall-runnerpulse install-runnerpulse-observer uninstall-runnerpulse-observer

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

build: bin/menumeter bin/TerminalClip.app/Contents/MacOS/TerminalClip bin/RunnerPulse.app/Contents/MacOS/RunnerPulse bin/DisplayPulse.app/Contents/MacOS/DisplayPulse

install-terminalclip: bin/TerminalClip.app/Contents/MacOS/TerminalClip
	mkdir -p $(HOME)/.local/opt
	rm -rf $(HOME)/.local/opt/TerminalClip.app
	ditto bin/TerminalClip.app $(HOME)/.local/opt/TerminalClip.app
	@echo "✓ TerminalClip installed to $(HOME)/.local/opt/TerminalClip.app"

# Force a clean rebuild and reopen the exact app bundle from this repository.
# This prevents the menu-bar icon from continuing to run an older version.
refresh-terminalclip:
	$(MAKE) -B bin/TerminalClip.app/Contents/MacOS/TerminalClip
	@pkill -x TerminalClip 2>/dev/null || true
	@sleep 1
	$(MAKE) install-terminalclip
	@open -n "$(HOME)/.local/opt/TerminalClip.app"
	@echo "✓ TerminalClip refreshed and reopened: $(HOME)/.local/opt/TerminalClip.app"
	@echo "  The redesigned popover shows v0.2 beside the title."

test-terminalclip: | bin
	$(SWIFTC) -D TERMINALCLIP_TEST tools/terminalclip/terminalclip.swift tools/terminalclip/tests/main.swift -o bin/terminalclip-tests
	./bin/terminalclip-tests
	@if [ "$$(uname -s)" = Darwin ]; then $(SWIFTC) -typecheck -framework AppKit -framework ApplicationServices -framework Carbon tools/terminalclip/terminalclip.swift; fi

install: build
	mkdir -p $(PREFIX)
	install -m 755 bin/menumeter $(PREFIX)/menumeter
	cp tools/menumeter/menumeter.swift $(PREFIX)/menumeter.swift
	@echo "✓ MenuMeter installed to $(PREFIX)/menumeter"
	$(MAKE) install-terminalclip
	$(MAKE) install-runnerpulse
	$(MAKE) install-displaypulse

uninstall-terminalclip:
	-pkill -x TerminalClip 2>/dev/null
	-launchctl bootout gui/$$(id -u)/com.terminalclip.local >/dev/null 2>&1
	rm -f $(HOME)/Library/LaunchAgents/com.terminalclip.local.plist
	rm -rf $(HOME)/.local/opt/TerminalClip.app
	@echo "✓ TerminalClip removed (Zsh configuration left untouched)"

uninstall: uninstall-terminalclip uninstall-runnerpulse uninstall-displaypulse
	pkill -x menumeter 2>/dev/null || true
	rm -f $(PREFIX)/menumeter
	rm -f $(PREFIX)/menumeter.swift
	rm -f $(HOME)/Library/LaunchAgents/com.user.menumeter.plist
	@echo "✓ MenuMeter uninstalled"

clean:
	rm -rf bin



# RunnerPulse: native AppKit + SwiftUI menu bar utility.
bin/RunnerPulse.app/Contents/MacOS/RunnerPulse: tools/runnerpulse/runnerpulse.swift tools/runnerpulse/Info.plist | bin
	mkdir -p bin/RunnerPulse.app/Contents/MacOS
	$(SWIFTC) -parse-as-library $(SWIFTFLAGS) -framework AppKit -framework SwiftUI -framework Security tools/runnerpulse/runnerpulse.swift -o bin/RunnerPulse.app/Contents/MacOS/RunnerPulse
	cp tools/runnerpulse/Info.plist bin/RunnerPulse.app/Contents/Info.plist
	-codesign --force --sign - bin/RunnerPulse.app

build-runnerpulse: bin/RunnerPulse.app/Contents/MacOS/RunnerPulse

install-runnerpulse: build-runnerpulse
	mkdir -p $(HOME)/.local/opt
	rm -rf $(HOME)/.local/opt/RunnerPulse.app
	ditto bin/RunnerPulse.app $(HOME)/.local/opt/RunnerPulse.app
	@echo "✓ RunnerPulse installed to $(HOME)/.local/opt/RunnerPulse.app"

refresh-runnerpulse:
	$(MAKE) -B build-runnerpulse
	@pkill -x RunnerPulse 2>/dev/null || true
	$(MAKE) install-runnerpulse
	@open -n "$(HOME)/.local/opt/RunnerPulse.app"

test-runnerpulse: | bin
	@# Prevent Xcode-only SwiftUI @State macros from breaking Command Line Tools builds.
	@if grep -Eq '^[[:space:]]*@State([[:space:]]|\(|$)' tools/runnerpulse/runnerpulse.swift; then \
		echo 'RunnerPulse compatibility check failed: @State requires SwiftUIMacros on newer macOS SDKs; use @Published + @ObservedObject.' >&2; \
		exit 1; \
	fi
	$(SWIFTC) -D RUNNERPULSE_TEST tools/runnerpulse/runnerpulse.swift tools/runnerpulse/tests/main.swift -o bin/runnerpulse-tests
	./bin/runnerpulse-tests
	@if [ "$$(uname -s)" = Darwin ]; then $(MAKE) build-runnerpulse; fi

uninstall-runnerpulse:
	-pkill -x RunnerPulse 2>/dev/null
	rm -rf $(HOME)/.local/opt/RunnerPulse.app
	@echo "✓ RunnerPulse removed (Keychain entry retained; remove token in app first)"


# Passive observer is a separate login LaunchAgent. Does not start or stop CI runners.
install-runnerpulse-observer:
	/bin/bash tools/runnerpulse/install-observer.sh

uninstall-runnerpulse-observer:
	-launchctl bootout gui/$$(id -u)/com.daniele.runnerpulse.observer >/dev/null 2>&1
	rm -f "$(HOME)/Library/LaunchAgents/com.daniele.runnerpulse.observer.plist"
	@echo "✓ Passive observer removed; GitHub runner services untouched"


# DisplayPulse: one-file native AppKit brightness control, optional m1ddc for hardware DDC/CI.
.PHONY: build-displaypulse install-displaypulse refresh-displaypulse test-displaypulse uninstall-displaypulse enable-displaypulse-login disable-displaypulse-login status-displaypulse-login

bin/DisplayPulse.app/Contents/MacOS/DisplayPulse: tools/displaypulse/displaypulse.swift tools/displaypulse/Info.plist tools/displaypulse/build-icon.sh tools/displaypulse/assets/DisplayPulse.webp | bin
	mkdir -p bin/DisplayPulse.app/Contents/MacOS
	$(SWIFTC) -parse-as-library $(SWIFTFLAGS) -framework AppKit tools/displaypulse/displaypulse.swift -o bin/DisplayPulse.app/Contents/MacOS/DisplayPulse
	cp tools/displaypulse/Info.plist bin/DisplayPulse.app/Contents/Info.plist
	@/bin/bash tools/displaypulse/build-icon.sh
	-codesign --force --sign - bin/DisplayPulse.app

build-displaypulse: bin/DisplayPulse.app/Contents/MacOS/DisplayPulse

install-displaypulse: build-displaypulse
	mkdir -p $(HOME)/.local/opt
	rm -rf $(HOME)/.local/opt/DisplayPulse.app
	ditto bin/DisplayPulse.app $(HOME)/.local/opt/DisplayPulse.app
	@echo "✓ DisplayPulse installed to $(HOME)/.local/opt/DisplayPulse.app"

refresh-displaypulse:
	$(MAKE) -B build-displaypulse
	@pkill -x DisplayPulse 2>/dev/null || true
	$(MAKE) install-displaypulse
	@open -n "$(HOME)/.local/opt/DisplayPulse.app"

test-displaypulse: build-displaypulse
	$(SWIFTC) -parse-as-library -D DISPLAYPULSE_TEST -framework AppKit tools/displaypulse/displaypulse.swift -o bin/displaypulse-probe-tests
	@bin/displaypulse-probe-tests --self-test
	@bin/DisplayPulse.app/Contents/MacOS/DisplayPulse --help | grep -q "brightness controller"
	@plutil -lint bin/DisplayPulse.app/Contents/Info.plist
	@/bin/bash -n tools/displaypulse/build-icon.sh
	@test -s bin/DisplayPulse.app/Contents/Resources/DisplayPulse.icns
	@# iconutil successfully built the container; test the resource exists and plist points to it.
	@test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' bin/DisplayPulse.app/Contents/Info.plist)" = "DisplayPulse.icns"
	@/bin/bash -n tools/displaypulse/login-item.sh
	@temp=$(mktemp); trap 'rm -f "$temp"' EXIT; \
		/bin/bash tools/displaypulse/login-item.sh render "$temp"; \
		test "$(/usr/libexec/PlistBuddy -c 'Print :Label' "$temp")" = "com.daniele.displaypulse"; \
		test "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$temp")" = "/usr/bin/open"; \
		test "$(/usr/libexec/PlistBuddy -c 'Print :RunAtLoad' "$temp")" = "true"; \
		test "$(/usr/libexec/PlistBuddy -c 'Print :LimitLoadToSessionType' "$temp")" = "Aqua"; \
		echo "DisplayPulse login item plist validation passed."

# Login-only launch: no sudo, no persistent shell or background polling.
# Explicit opt-in: installing the app alone does not modify login settings.
enable-displaypulse-login: install-displaypulse
	@/bin/bash tools/displaypulse/login-item.sh enable

disable-displaypulse-login:
	@/bin/bash tools/displaypulse/login-item.sh disable

status-displaypulse-login:
	@/bin/bash tools/displaypulse/login-item.sh status

uninstall-displaypulse:
	@/bin/bash tools/displaypulse/login-item.sh disable
	-pkill -x DisplayPulse 2>/dev/null
	rm -rf $(HOME)/.local/opt/DisplayPulse.app
	@echo "✓ DisplayPulse uninstalled"
