# macOS Micro-Tools

A curated collection of **single-file, zero-dependency, Apple-native micro-utilities** for macOS power users, software engineers, and AI developers.

---

## Philosophy

Most modern macOS utilities suffer from feature creep: multi-gigabyte Electron runtimes, persistent background telemetry, subscriptions, or complex multi-module Xcode build requirements.

**macOS Micro-Tools** are built with a different philosophy:
- **Single-File & Zero Dependencies**: Each tool is self-contained in a single `.swift` source file. No external packages, no CocoaPods, no SPM.
- **Compiled with Native Tools**: Builds directly with `swiftc -O` already included in macOS Command Line Tools.
- **Radical Efficiency**: Native AppKit & Mach/Darwin APIs. Extremely low memory footprint (<50 MB) and negligible idle CPU usage.
- **100% Hackable & Transparent**: Easily inspectable, auditable, and customizable.

---

## Included Tools

| Tool | Description | Status |
| :--- | :--- | :--- |
| [**MenuMeter**](tools/menumeter/) | Minimalist CPU, RAM, Memory Pressure, Swap I/O, Thermal State, and Top Process dashboard in your menu bar. | Stable (v3) |
| [**TerminalClip**](tools/terminalclip/) | Copy Terminal.app output with ⌘⌥C, optional Zsh command/exit code metadata and diagnostic reports. | MVP (UI 0.2; macOS interaction test pending) |
| [**RunnerPulse**](tools/runnerpulse/) | Monitor GitHub Actions self-hosted runners, workflow jobs, current steps, queue and failures in the menu bar. | MVP (v0.1) |
| [**DisplayPulse**](tools/displaypulse/) | Hardware DDC/CI brightness test and fallback per-screen software dimmer in the menu bar. | MVP (v0.1; Atlantis hardware probe pending) |

*More tools (local port monitor, AI VRAM monitor, and sleep toggles) are planned.*

---

## Quick Start

### 1. Requirements
macOS 13.0+ and Command Line Tools (already present if you have Xcode or run `xcode-select --install`).

### 2. Installation

Clone and install with `make`:

```bash
git clone https://github.com/daniele21/macos-microtools.git
cd macos-microtools
make install
```

This compiles each tool with optimizations and places the binaries in `~/.local/bin/`.

Ensure `~/.local/bin` is in your `PATH` by adding this to your `~/.zshrc`:
```bash
export PATH="$HOME/.local/bin:$PATH"
```

To run MenuMeter:
```bash
menumeter &
```

To launch RunnerPulse:
```bash
open "$HOME/.local/opt/RunnerPulse.app"
```

To launch TerminalClip:
```bash
open "$HOME/.local/opt/TerminalClip.app"
```

If a previous TerminalClip process still shows the original five grey buttons, run `make refresh-terminalclip` after updating the feature branch to force rebuild and restart the v0.2 UI.

TerminalClip's optional Zsh metadata capture is **disabled by default**. For setup, privacy caveats and testing see [TerminalClip](tools/terminalclip/README.md). Install only TerminalClip with `make install-terminalclip` and test it with `make test-terminalclip`.

---

RunnerPulse connects to the GitHub REST API using a fine-grained read-only token saved in macOS Keychain. Configure monitored repositories in its settings. Use `make install-runnerpulse` for only RunnerPulse, `make refresh-runnerpulse` to rebuild and relaunch, and `make test-runnerpulse` for unit and native build checks. See [RunnerPulse setup and permissions](tools/runnerpulse/README.md).

## Tool Highlights: MenuMeter

MenuMeter lives in your menu bar showing `CPU XX% · RAM XX%`. Clicking it reveals a custom two-column dashboard:

- **CPU Column**: Current total, 60-second real-time sparkline, collapsible per-core load gauges, and top 3 CPU processes.
- **RAM Column**: 60-second sparkline, true Kernel **Memory Pressure** (`● Normale`, `▲ Attenzione`, `■ Critica`), memory category breakdown (Active, Wired, Compressed, Free, Swap), and real-time **Swap I/O rate** (distinguishing dormant swap from active disk thrashing).
- **Diagnostics**: Thermal State monitor (`Nominale`, `Moderato`, `Elevato`) and a **Copia diagnostica** button that formats and copies a comprehensive performance report to your clipboard with one click.
- **Interactive Top Processes**: Scanned strictly on-demand when the popover is opened (0% background cost). Click to jump to the app or inspect in Activity Monitor.

---

## Contributing

Suggestions and contributions are welcome! If you have ideas for lightweight, single-file native micro-utilities for macOS, feel free to open an issue or pull request.

---

## License

MIT License © 2026 Daniele Moltisanti


## DisplayPulse

DisplayPulse supports optional m1ddc for real hardware brightness and a built-in software dimmer fallback. The Atlantis A05-P156WP's DDC/CI support is **not verified** yet. Install only this app with `make install-displaypulse`, open `~/.local/opt/DisplayPulse.app` and follow the [read-only probe instructions](tools/displaypulse/README.md). To start the menu-bar app automatically on every macOS login, run `make enable-displaypulse-login` once; inspect with `make status-displaypulse-login` or remove with `make disable-displaypulse-login`. This creates only a per-user LaunchAgent, without sudo or a persistent terminal.
