# LEDPulse — AppleSMC discovery (experimental)

Independent MIT-licensed low-level Swift CLI. No LuxMini code or device profiles.
Uses the private AppleSMC IOKit protocol: 80-byte request, user client type 0,
selector 2; read bytes (5), enumerate key (8), metadata (9). The public
[Chromium SMC protocol definitions](https://chromium.googlesource.com/chromium/src/+/refs/tags/143.0.7473.1/components/power_metrics/smc_internal_types_mac.h)
and [SMCKit](https://github.com/beltex/SMCKit) document the interface.

## Build and run on macOS 13+

From the repository root:

```sh
make -C tools/ledpulse
tools/ledpulse/ledpulse-smc self-test
tools/ledpulse/ledpulse-smc discover > /tmp/ledpulse-discovery.json
cat /tmp/ledpulse-discovery.json
```

Discovery enumerates keys and returns **metadata only** for possible LED-related
names (L*, MSL*, LED/SIL substring); it can miss opaque keys and can include unrelated
keys. No bulk sensor values, serial numbers, or network requests. Inspect the JSON
locally before sharing. Explicit `info KEY` and `read KEY` are available for
specific keys; reads of sensitive keys should not be shared. Example:
`tools/ledpulse/ledpulse-smc read FNum`.

No sudo, no helper, no SIP changes, no firmware writes. Some devices or OS versions
may refuse even read access. An enumeration with nonzero indexErrors is incomplete.
Unknown types retain their raw hex rather than guessing a numeric interpretation.
The private protocol may change; hardware testing is required.

The next step is to identify and independently verify a model-specific LED profile
(including type, size, state semantics and restore procedure). Do not test by
writing guessed keys. Only then add a separate allowlisted write backend and a
privileged helper if required. The mock self-test is not evidence of hardware support.
