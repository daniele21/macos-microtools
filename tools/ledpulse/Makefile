SWIFTC ?= swiftc
.PHONY: all test clean
all: ledpulse-smc
ledpulse-smc: ledpulse-smc.swift
	$(SWIFTC) -O -framework IOKit $< -o $@
test: ledpulse-smc
	./ledpulse-smc self-test
clean:
	rm -f ledpulse-smc
