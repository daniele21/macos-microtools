# PowerPulse — Phase 0: hardware discovery

A short-lived, read-only native Swift probe for Apple Silicon macOS 13+. No sudo, external packages, persistent agent, network calls or settings changes. This is not yet a menu-bar app.

From the repository root:

```sh
make test-powerpulse-probe
make build-powerpulse-probe
./bin/powerpulse-probe --samples 5 --interval 1 > powerpulse-idle.json
```

Repeat while a normal existing build or local LLM inference is active:

```sh
./bin/powerpulse-probe --samples 5 --interval 1 > powerpulse-load.json
```

Share both JSON reports to determine which sensors respond under load. Do not start a synthetic stress test merely to collect a report. Default: 3 samples, 1 second apart. Range: 1–60 samples, 0.25–10 seconds per interval.

## Interpretation

- IOReport Energy Model: raw channel labels, units, interval deltas and calculated watts for recognized energy units. Channels may overlap (CPU aggregate versus clusters, for example); do not sum them indiscriminately.
- AppleSMC: PSTR (system-total candidate), PDTR (DC-input candidate), fan-count and RPM keys, selected temperature keys. The actual meanings and availability must be confirmed on each hardware model. No enumeration of arbitrary keys.
- Both PSTR and PDTR are internal readings, not necessarily AC wall draw. They are separate candidates, not additive. A wall meter is needed for actual AC energy validation.
- Missing or unsupported sensors have absent numeric values and an explicit status. A zero energy delta or zero watt sensor is marked zero_unverified; this may represent idle or a frozen/blocked counter.
- macOS 27 can expose Energy Model channels without updating them for unprivileged callers. Compare actual idle and load results. No attempt is made to bypass access controls or use a private entitlement.
- No persistent sampler, CLPC fallback, process attribution, fan control, temperature aggregation, energy history or cost calculation in phase 0.
- Reports contain model identifier and macOS version, but do not collect a serial number, username, process names or commands.

## Tests

`make test-powerpulse-probe` builds and executes deterministic tests for unit conversion, invalid values and SMC payload decoding. This does not certify private API behavior. Native Apple Silicon hardware validation is required separately. On a non-macOS machine the source can compile for its portable `--self-test` only.

## Technical references

- Apple OSS PowerManagement: https://github.com/apple-oss-distributions/PowerManagement
- IOReport compatibility and counter limitations: https://github.com/vladkens/macmon
- SMC protocol and type notes: https://github.com/omar16100/fanpro/blob/main/docs/smc_reference.md

The probe resolves private IOReport symbols at runtime; neither private ABI nor SMC keys have public stability guarantees. Only key-info and read commands are sent to AppleSMC.
