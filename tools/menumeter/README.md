# MenuMeter v5.0

A minimalist, high-performance macOS menu bar monitor for CPU, integrated GPU, RAM, Memory Pressure, Swap I/O, and Thermal State.

Written in a single Swift file using native Apple frameworks (AppKit, Mach, Darwin, IOKit). Zero third-party dependencies, zero Electron, zero bloat (<45MB RAM footprint, 0% idle CPU).

---

## What changed in v5.0

- **First-glance overview is the default popover:** CPU, GPU and RAM as equal-sized, color-coded metric cards (percentage, slim usage bar and context), memory-health status with swap usage, and top three processes.
- **Two-level navigation:** `Panoramica` for a quick status check, `Dettagli` for the full 60-second charts, per-core CPU, GPU renderer/tiler, unified memory, pressure history, swap I/O and the full process table. Clicking any metric card jumps to its resource details; `Tutti i processi` opens the advanced process table.
- **Process preview:** CPU/RAM sort and recognizable app names/icons, with CPU and RAM RSS in the same row. Process metadata still refreshes only while the popup is open (at most every 6 seconds).
- **Native AppKit, adaptive appearance:** cards and typography use native semantic colors; no extra collectors, external tools or dependencies. The overview shares the existing CPU/GPU/RAM samples and memory-pressure health assessment.
- **Stable popup:** 610pt wide, a fixed-height scroll viewport and a pinned footer with diagnostics, login, and quit controls. The more technical view can scroll independently. Normal first-glance usage doesn't require navigating all the raw memory components.

## What changed in v4.3

- **Stable menu bar width:** a fixed-size status item and fixed-width percentages mean CPU/GPU/RAM updating does not move neighboring macOS icons. Missing readings use `—`, with space reserved for RAM alerts.
- **At-a-glance menu bar:** small blue (CPU), purple (GPU), and green (RAM) indicators with matching values; labels remain neutral. RAM turns amber/red for sustained memory-health warnings; missing sensor data is neutral. Color is supplemental to the CPU/GPU/RAM text, never the sole identifier.
- **One full-width top-process table:** use the footer's `Processi ↓` shortcut to jump below the metrics; select CPU or RSS ranking and choose applications or individual processes; show the first 5 rows (up to 12 on demand). Columns display CPU and RSS side by side.
- **Readable process names:** app bundle names (including nested helpers, such as Chromium-based browsers), executable basenames, and optional app icons; raw paths are visible when expanding a row.
- **Expandable on-demand details:** click a row for PID(s), executable, full command fetched via `ps` only on demand, and an explicit shortcut to Activity Monitor.
- **Safe aggregation:** only processes with the same identifiable outer `.app` bundle are grouped; independent Python/Node jobs remain separate. Per-process %CPU can exceed 100% because 100% means one logical CPU; grouped RSS is approximate due to shared pages.
- **Lightweight monitoring retained:** CPU/GPU/RAM sample every 2 seconds; the process snapshot still refreshes at most every 6 seconds, only while the popover is visible.
- **Added deterministic regression tests** for fixed status text widths, nested application paths, sort order, app grouping, and CLI isolation.

## What changed in v4.2

- **Integrated GPU next to CPU and RAM in the menu bar**: refreshed every 2 seconds using the graphics driver's native IOKit `PerformanceStatistics` (no `sudo` or spawned `ioreg` process).
- **Compact GPU section under CPU** in the existing two-column popover: utilization and 60-second trend, optional renderer/tiler activity, GPU core count where exposed, and shared GPU memory in use / allocated.
- **GPU data is driver-dependent**: missing metrics render `—` / `Statistiche GPU non disponibili`, *not* 0%. On systems with multiple reporting GPUs, the status bar shows the highest reported utilization; GPU percentages are not additive.
- **Apple Silicon unified memory**: GPU memory figures overlap with the system RAM view and must not be summed or interpreted as dedicated VRAM.
- **GPU snapshot in copied diagnostics**, with parser tests for missing, invalid, and alternate driver keys.

## What changed in v4.1

- **Top RAM/RSS is visible higher in the RAM column**, immediately after the pressure health summary rather than after every memory bar and swap chart.
- **Scrollable dashboard** with a fixed-height viewport: no hidden bottom rows when the available menu bar display height is limited, or when CPU cores are expanded. The footer stays accessible.
- **Immediate process sampling when the popover opens** instead of waiting up to two seconds for the next timer tick.
- **Explicit loading/empty/error state** in both CPU and RSS process sections. An empty process scan no longer fails silently.
- **Robust macOS \`ps\` parsing**: whitespace-agnostic and independent of column headers or current locale, with smoke tests using the actual \`/bin/ps\` in macOS CI.

## What changed in v4

- **Swap is not a fixed-capacity meter:** the dashboard shows disk swap used as an amount; the dynamically allocated total is available in a tooltip and copied diagnostics. A nearly full allocated amount is not itself an alert.
- **Pressure timeline (60s):** a compact strip of kernel memory-pressure states (green/yellow/red), sampled every 2 seconds.
- **Swap I/O trend (60s):** direction-aware instantaneous rates (↓ swap-in reads and ↑ swap-out writes), plus rolling peak. The chart auto-scales to its displayed peak.
- **Sustained memory-health indicator** beside the memory section, with a matching ▲/■ in the menu bar only after:
  - >= 6 seconds of continuous critical pressure;
  - >= 30 seconds of continuous elevated/critical pressure; or
  - >= 20 seconds of sustained swap I/O >= 5 MiB/s.
- **Rate labels use MiB/s and KiB/s**, matching the actual binary divisor.
- **Lower background overhead:** top-process scan is still on-demand, but also throttled to at most once every 6 seconds while the popover is open.
- **No destructive action**: MenuMeter never empties swap or terminates memory-hungry processes automatically.

These are pragmatic alert thresholds, not Apple-defined pressure thresholds or diagnostic proof of thrashing. A two-second sampling period means brief events can be missed. Process RSS estimates are not additive. The CPU and RAM percentages, pressure signal and swap rates answer different questions.

## Features

- **Dashboard Layout**: Compact three-card overview, with the original two-column advanced diagnostics and full-width Top Processi table in the Details tab with an opaque, solid-background `NSPopover`.
- **60-Second Sparklines**: Real-time visual history for CPU, GPU (when available), and RAM over the last 60 seconds (30 samples @ 2s).
- **Collapsible CPU Cores**: Shows total CPU load by default, with an expandable `▾ Core` section to inspect individual core loads.
- **True Memory Pressure**: Directly queries kernel memory pressure (`kern.memorystatus_vm_pressure_level`) with clear states:
  - `● Normale` (Green)
  - `▲ Attenzione` (Yellow)
  - `■ Critica` (Red)
- **Active Swap I/O Tracking**: Distinguishes between dormant disk swap and active memory thrashing (direction-aware ↓ swap-in and ↑ swap-out rates, plus the 60s trend).
- **Top Processes (On-Demand)**:
  - Scanned **only while the popover is open**, at most once every 6 seconds.
  - CPU/RAM sort, grouped app / individual process mode, stable PID association.
  - Click a row for details; full command is retrieved on demand. Click the explicit Activity Monitor button to open it.
- **Mac Thermal State**: Displays hardware thermal status (`ProcessInfo.thermalState`) to identify thermal throttling during builds or local AI inference.
- **One-Click Diagnostic Snapshot**: Click `[Copia diagnostica]` to copy a structured diagnostic report straight to your clipboard.
- **Auto-start at Login**: Built-in toggle to register/deregister a LaunchAgent in `~/Library/LaunchAgents/`.

---

## Build & Install

```bash
# From the repository root:
make install

# Rebuild and restart ONLY MenuMeter after updates:
make refresh-menumeter

# Native macOS typecheck + deterministic memory-health tests:
make test-menumeter
```

Or compile manually in one command:
```bash
swiftc -O -framework AppKit -framework IOKit tools/menumeter/menumeter.swift -o ~/.local/bin/menumeter
~/.local/bin/menumeter &
```

---

## Keyboard & Mouse Shortcuts

- **Click status bar icon**: Toggle dashboard popover.
- **Click on process row**: Expand details (PID, binary, command, CPU, RSS); use the dedicated button to launch Activity Monitor.
- **Sort and group**: Switch between CPU/RAM and App/Processi; expand the 5 initial rows to 12.
- **Click "Copia diagnostica"**: Copies diagnostic summary to clipboard.
- **Click "Esci"**: Terminates MenuMeter cleanly.

