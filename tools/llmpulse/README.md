# LLMPulse

**Your own native, zero-SDK macOS menu bar monitor** for Codex, Claude Code and Google Antigravity quotas.

Each provider uses the installed vendor CLI/session directly. CodexBar is **not** required.
LLMPulse reads and normalizes independent quota windows and shows **remaining percentages**,
time to reset, capture age and a warning/critical icon near exhaustion. No provider credentials,
transcripts, conversation texts or session identifiers are written to disk.

## Progressive-disclosure menu bar (v0.2)

One LLMPulse process creates **three separate fixed-width status items**, with a
provider symbol, a numeric five-hour utilization percentage, a smaller
weekly number in parentheses, and a thin gauge. For example, `12% (28)`
means **12% used in the past 5 hours** and **28% used in the weekly quota**.
The parenthesized weekly figure is deliberately smaller, and turns amber/red
only if the weekly remaining allowance becomes low. A missing/stale weekly
value is shown as `(—)`, never as zero. The two numbers come from the same
Codex limit or Antigravity model group; quotas are never summed.

You can read both figures without opening any popover. The default shows **used
quota**; Settings can switch all three indicators to **remaining quota**. A near-limit quota changes color
(orange at <=25% remaining, red at <=10%). Unknown/old readings show `—`,
never a made-up `0%`.

Each icon opens **only that provider's** compact popup. You first see 5-hour
and weekly quota plus reset information; expand **Altre quote / Gruppi e altre
quote** to reveal additional buckets. Click the gear in any popup to configure
used vs remaining, enabled providers and automatic polling. At least one icon
always stays available so Settings remains reachable.

**Antigravity has distinct group quotas**, not a unified 5-hour allowance.
By default the menu bar displays the most limiting valid 5-hour bucket and
its tooltip tells you which group it belongs to. To pin a family instead,
open the Antigravity popup and expand `Gruppi e altre quote`, or choose the
group in Settings. Weekly-only model families show `—` for their missing
5-hour quota; their weekly reading remains visible after clicking.

The three menu items use a compact **96 pt fixed width** (instead of 112 pt),
reducing horizontal gaps without shifting neighboring menu extras as values change
between `9% (9)`, `99% (100)`, `100% (100)` and `— (—)`.
Each provider keeps its identifiable macOS accent in the small quota gauge:
**Codex teal**, **Claude orange**, **Antigravity indigo**. The icon and both
numeric percentages use semantic, appearance-adaptive system label colors for
legibility over arbitrary translucent menu-bar wallpapers and highlighted states.
The five-hour value is 11pt semibold; weekly uses 10pt medium, but is no
longer faded to low-contrast secondary gray. The gauge also has a neutral
contrasting track/outline. Low allowances still use an orange/red gauge.

Provider identification never depends on color alone: each item has its own
symbol and a tooltip naming the provider, the five-hour/weekly quotas, and reset
times. The final visual contrast depends on macOS window/menu-bar material and
the desktop wallpaper and should be checked in both light and dark appearances.
For additional contrast on macOS, use System Settings → Accessibility → Display →
Increase Contrast / Reduce Transparency. The refresh
timer runs every five minutes; a separate local-file check every 12 seconds
picks up fresh Claude status-line events while the popup is closed. Existing
provider sessions, no-session credential policy and cache format are unchanged.

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
