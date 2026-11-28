SWIFTC ?= swiftc
.PHONY: all test clean
all: ledpulse-smc
ledpulse-smc: ../shared/AppleSMC.swift ledpulse-smc.swift
	cat $^ > .ledpulse-combined.swift
	$(SWIFTC) -O -framework IOKit .ledpulse-combined.swift -o $@
test: ledpulse-smc
	./ledpulse-smc self-test
clean:
	rm -f ledpulse-smc .ledpulse-combined.swift
