PREFIX ?= $(HOME)/.local/bin
SWIFTC ?= swiftc
SWIFTFLAGS = -O

.PHONY: all build install clean uninstall

all: build

bin:
	mkdir -p bin

bin/menumeter: tools/menumeter/menumeter.swift | bin
	$(SWIFTC) $(SWIFTFLAGS) tools/menumeter/menumeter.swift -o bin/menumeter

build: bin/menumeter

install: build
	mkdir -p $(PREFIX)
	install -m 755 bin/menumeter $(PREFIX)/menumeter
	cp tools/menumeter/menumeter.swift $(PREFIX)/menumeter.swift
	@echo "✓ MenuMeter installed to $(PREFIX)/menumeter"

uninstall:
	pkill -x menumeter 2>/dev/null || true
	rm -f $(PREFIX)/menumeter
	rm -f $(PREFIX)/menumeter.swift
	rm -f $(HOME)/Library/LaunchAgents/com.user.menumeter.plist
	@echo "✓ MenuMeter uninstalled"

clean:
	rm -rf bin

