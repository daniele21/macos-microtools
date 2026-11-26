# LLMPulse

**Your own native, zero-SDK macOS menu bar monitor** for Codex, Claude Code and Google Antigravity quotas.

Each provider uses the installed vendor CLI/session directly. CodexBar is **not** required.
LLMPulse reads and normalizes independent quota windows and shows **remaining percentages**,
time to reset, capture age and a warning/critical icon near exhaustion. No provider credentials,
transcripts, conversation texts or session identifiers are written to disk.

## Progressive-disclosure menu bar

LLMPulse creates three separate, fixed-width macOS status items. Choose the
density in the gear menu of any provider popover. The setting persists across
restarts, and updates all visible providers immediately.

- **Compact (default):** icon and `12·7`, meaning 12% of the five-hour quota
  consumed and 7% of the weekly quota consumed. The weekly number is slightly
  smaller. Fixed width: **60 pt** per provider.
- **Minimal:** icon and `12`, meaning 12% of the five-hour quota consumed.
  Weekly quota remains available in the tooltip and popover. Fixed width:
  **40 pt** per provider.

With three providers visible, the total allocated widths are 180 pt and 120 pt
respectively, compared with 288 pt previously (excluding system spacing).
The icon and both numbers are drawn together as a native template image,
with a two-point gap, instead of using the status button's image/title layout.
AppKit font measurements are checked for `100·100` in native CI.
There are no separate progress gauges, repeated percent signs or parentheses
in the menu bar. Missing or stale values are always `—`, not fabricated
zeros. The layout remains stable even at `100·100`. Compact is the default
for new and existing installations without a saved density preference.
Minimal is a manual choice; macOS does not expose a reliable free-space
measurement for third-party status items, so widths are not changed
automatically according to other applications.

The icon and numbers use native, appearance-adaptive system colors for
legibility against arbitrary menu-bar backgrounds. Provider identity remains
recognizable by its symbol; teal, orange and indigo accents are used in
the respective popover headers. Full-color quota bars and risk indicators
remain in the popovers.

Each icon opens only its provider's detail. Hover to see both percentages,
their units and reset times; the global consumed/remaining setting applies
to both. The gear also offers provider visibility and automatic polling.
At least one provider remains visible so Settings stays accessible.

Antigravity has distinct model-group quotas. Its automatic mode shows
the most limiting valid five-hour bucket and the corresponding weekly
bucket, never a sum of unrelated quotas. Pin a group in the popover or
Settings. Weekly-only groups show `—` for their absent five-hour quota.

The refresh timer runs every five minutes; a separate local-file check
every 12 seconds picks up fresh Claude status-line events. Provider
integrations, cache format, and existing settings are unchanged.

## Install

Requires macOS 13+ and Xcode Command Line Tools.

```bash
make test-llmpulse
make install-llmpulse
open "$HOME/.local/opt/LLMPulse.app"
```

Only LLMPulse: `make refresh-llmpulse` rebuilds and relaunches the app. The installation
does **not** enable a login item or modify Claude Code settings.
To opt into login startup: `make enable-llmpulse-login`.
To disable it: `make disable-llmpulse-login`.

### If macOS refuses to open LLMPulse (-10825)

LaunchServices error `-10825` means the binary requires a newer macOS
version than the machine currently runs. `Info.plist` alone cannot override
the Mach-O deployment target, so LLMPulse explicitly compiles the app **and**
the Claude ingest helper with minimum macOS 13.0.

On the Mac, after updating your checkout:

```bash
sw_vers -productVersion    # Must be 13.0 or later
make refresh-llmpulse      # Force rebuild, reinstall, and open
xcrun vtool -show-build "$HOME/.local/opt/LLMPulse.app/Contents/MacOS/LLMPulse"
```

Look for `minos 13.0` in the diagnostic output. If your installed macOS is older
than 13.0, LLMPulse v0.1 is not supported. The login LaunchAgent does not need
to be re-enabled after refreshing the app. If `open` still fails despite a
compatible `minos`, run the executable directly to inspect its startup error:

```bash
"$HOME/.local/opt/LLMPulse.app/Contents/MacOS/LLMPulse"
```

## Providers

| Provider | Method | Important constraints |
| --- | --- | --- |
| Codex | `codex app-server`, JSON-RPC initialize → initialized → `account/rateLimits/read` | Read-only request; uses existing Codex CLI sign-in; no Codex thread is started |
| Claude Code | `statusLine` callback JSON → `LLMPulseIngest` | Callback runs when Claude has events; fields only present after first API response; current statusline config is NOT edited |
| Antigravity | `agy -p /usage --output-format json` | Reads quota buckets per model family, not one synthetic percentage; availability depends on installed CLI/sign-in; CLI may have its own local startup behavior |

The application refreshes every 5 minutes by default and allows manual refresh.
It does not send any generative prompts. Antigravity disables child auto-updates
and sets a non-interactive BROWSER environment hint; these hints cannot guarantee
that future versions of the vendor CLI won't request authentication, so test
with a working existing login. A failed fetch is **not** shown as 0% usage.

For a private custom executable path:
```bash
LLMPULSE_CODEX_PATH=/absolute/path/to/codex
LLMPULSE_AGY_PATH=/absolute/path/to/agy
```
These are optional. When set, an invalid override is an explicit missing-CLI
error; the app never silently falls back to another binary.

### Collegamento Claude automatico (consigliato)

Dalla menu bar, fai clic sull'icona Claude Code di LLMPulse e premi
**Collega Claude Code**. Eseguire comandi nel Terminale non serve.

Il pulsante configura una volta sola `~/.claude/settings.json` e non modifica
le altre impostazioni. Se Claude ha già una status line personalizzata,
LLMPulse crea un bridge locale che inoltra lo stesso JSON sia a
`LLMPulseIngest` sia al precedente comando, conservandone l'output e creando
una copia di sicurezza `settings.json.llmpulse-backup-*` (permessi 0600).
Una seconda pressione è idempotente. L'installazione non cambia mai
`settings.json` in automatico, senza il tuo clic esplicito.

**Questa configurazione non crea richieste AI.** Le quote arrivano quando
Claude Code invia i dati attraverso la sua status line durante una sessione
attiva, normalmente dopo la prima risposta del modello. In assenza di una
sessione attiva, il menu mostra `—` per il dato live; il popover distingue
collegamento attivo, primo dato ancora non ricevuto e ultima rilevazione
disponibile ma non aggiornata. Non occorrono script diagnostici ricorrenti.

Per anomalie, il popover mostra automaticamente lo stato del collegamento.
Se `settings.json` non è un oggetto JSON valido, LLMPulse non lo sovrascrive.
In un ambiente con impostazioni Claude gestite a livello organizzativo,
le preferenze locali possono essere ignorate da Claude Code.

### Claude Code status line setup

The Claude Code status-line callback receives rate limits as JSON on stdin:
`rate_limits.five_hour.used_percentage` and
`rate_limits.seven_day.used_percentage`. Model-specific weekly limits are
not consistently provided by this callback; LLMPulse will not fabricate them.

**Configurazione manuale alternativa**, quando non esiste già una status line, aggiungi a
`~/.claude/settings.json` (merge into the existing JSON, do not replace it):
```json
{
  "statusLine": {
    "type": "command",
    "command": "$HOME/.local/opt/LLMPulse.app/Contents/MacOS/LLMPulseIngest"
  }
}
```

The Foundation-only `LLMPulseIngest` helper avoids launching the GUI frameworks on each Claude callback.
Once Claude processes a request, the status line will display a small readable
quota string and LLMPulse will receive a private snapshot.

**If you already have a custom Claude status line, do not overwrite it.**
Instead create your own wrapper script:

```bash
#!/bin/zsh
payload=$(cat)
printf '%s' "$payload" | "$HOME/.local/opt/LLMPulse.app/Contents/MacOS/LLMPulseIngest" --silent
printf '%s' "$payload" | "$HOME/.claude/my-existing-statusline.sh"
```

Then set `statusLine.command` to the full path of this wrapper. Replace the
last command with your actual existing status-line command and keep it
executable. The payload is kept in memory; the LLMPulse sink only persists
filtered quota percentages, reset timestamps and capture time. No automatic
modification to `settings.json` is performed. The script may execute more
than once per minute on active sessions, so the sink is quick and offline.

## Privacy and failure behavior

- App data: `~/Library/Application Support/LLMPulse/` (0600 quota files in private directory).
- Never reads `~/.codex/auth.json`, Claude Keychain values or browser cookies.
- No plaintext access tokens, account emails or chat messages are stored.
- Provider refreshes are independent; one failure does not clear other quotas.
- A cached quota older than 15 minutes is explicitly marked as old.
- If a window passes its reset time without another vendor report, it is marked
  "Reset da verificare", rather than pretending a fresh full allowance.
- Running CLI refresh does not itself guarantee zero login-side effects of a vendor CLI.

## Build and tests

```bash
make test-llmpulse
make build-llmpulse
make install-llmpulse
make uninstall-llmpulse
```

Tests check Codex multi-bucket and legacy JSON, Claude missing/invalid rate limit
payloads, Antigravity family buckets, percentage semantics, independent reset
times and cache provider isolation. Presentation tests additionally cover
five-hour-only menu indicators, stale/missing data, vendor-specific weekly
pairing, Antigravity automatic/pinned groups, and used/remaining semantics.

### Documentation for integrations

- Codex App Server: https://learn.chatgpt.com/docs/app-server
- Claude Code status line: https://code.claude.com/docs/en/statusline
- Antigravity CLI: https://antigravity.google/docs/cli/reference/

## Current limitations (v0.1)

Native macOS build and parser tests are validated in the macOS GitHub
Actions workflow. Live provider integration requires your logged-in Mac. There is no automated Claude setup because it
must not clobber an existing status line. No API-usage billing or synthetic
overall %; subscription quotas and API token accounting are separate.
