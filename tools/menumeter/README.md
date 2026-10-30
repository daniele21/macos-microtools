# MenuMeter

A minimalist, high-performance macOS menu bar monitor for CPU, RAM, Memory Pressure, Swap I/O, and Thermal State.

Written in a single Swift file using 100% native Apple frameworks (AppKit, Mach, Darwin). Zero third-party dependencies, zero Electron, zero bloat (<45MB RAM footprint, 0% idle CPU).

---

## Features

- **Dashboard Layout**: Side-by-side columns (CPU on the left, RAM on the right) with an opaque, solid-background `NSPopover`.
- **60-Second Sparklines**: Real-time visual history for both CPU and RAM over the last 60 seconds (30 samples @ 2s).
- **Collapsible CPU Cores**: Shows total CPU load by default, with an expandable `▾ Core` section to inspect individual core loads.
- **True Memory Pressure**: Directly queries kernel memory pressure (`kern.memorystatus_vm_pressure_level`) with clear states:
  - `● Normale` (Green)
  - `▲ Attenzione` (Yellow)
  - `■ Critica` (Red)
- **Active Swap I/O Tracking**: Distinguishes between dormant disk swap and active memory thrashing (`Inattiva (0 KB/s)` vs `Attiva: in X MB/s · out Y MB/s`).
- **Top Processes (On-Demand)**:
  - Scanned **only when the popover is opened** (zero background CPU usage).
  - Tracked by distinct PID with app names resolved via `NSRunningApplication`.
  - **Interactive**: Hover for full details, click to activate the application or inspect in Activity Monitor.
- **Mac Thermal State**: Displays hardware thermal status (`ProcessInfo.thermalState`) to identify thermal throttling during builds or local AI inference.
- **One-Click Diagnostic Snapshot**: Click `[Copia diagnostica]` to copy a structured diagnostic report straight to your clipboard.
- **Auto-start at Login**: Built-in toggle to register/deregister a LaunchAgent in `~/Library/LaunchAgents/`.

---

## Build & Install

```bash
# From the repository root:
make install
```

Or compile manually in one command:
```bash
swiftc -O tools/menumeter/menumeter.swift -o ~/.local/bin/menumeter
~/.local/bin/menumeter &
```

---

## Keyboard & Mouse Shortcuts

- **Click status bar icon**: Toggle dashboard popover.
- **Hover on top process**: View detailed tooltip (PID, exact CPU %, RSS RAM).
- **Click on top process**: Bring app to front or open Activity Monitor.
- **Click "Copia diagnostica"**: Copies diagnostic summary to clipboard.
- **Click "Esci"**: Terminates MenuMeter cleanly.
