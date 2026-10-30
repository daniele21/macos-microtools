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
| [**TerminalClip**](tools/terminalclip/) | Copy Terminal.app output with ⌘⌥C, optional Zsh command/exit code metadata and diagnostic reports. | MVP (0.1; macOS smoke test pending) |

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

To launch TerminalClip:
```bash
open "$HOME/.local/opt/TerminalClip.app"
```

TerminalClip's optional Zsh metadata capture is **disabled by default**. For setup, privacy caveats and testing see [TerminalClip](tools/terminalclip/README.md). Install only TerminalClip with `make install-terminalclip` and test it with `make test-terminalclip`.

---

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

