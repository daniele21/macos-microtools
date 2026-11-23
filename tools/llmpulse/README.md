# LLMPulse

**Your own native, zero-SDK macOS menu bar monitor** for Codex, Claude Code and Google Antigravity quotas.

Each provider uses the installed vendor CLI/session directly. CodexBar is **not** required.
LLMPulse reads and normalizes independent quota windows and shows **remaining percentages**,
time to reset, capture age and a warning/critical icon near exhaustion. No provider credentials,
transcripts, conversation texts or session identifiers are written to disk.

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

### Claude Code status line setup

The Claude Code status-line callback receives rate limits as JSON on stdin:
`rate_limits.five_hour.used_percentage` and
`rate_limits.seven_day.used_percentage`. Model-specific weekly limits are
not consistently provided by this callback; LLMPulse will not fabricate them.

**Manual opt-in**, when no custom status line currently exists, add to
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
printf '%s' "$payload" | "$HOME/.local/opt/LLMPulse.app/Contents/MacOS/LLMPulse" --claude-ingest-only
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
times and cache provider isolation.

### Documentation for integrations

- Codex App Server: https://learn.chatgpt.com/docs/app-server
- Claude Code status line: https://code.claude.com/docs/en/statusline
- Antigravity CLI: https://antigravity.google/docs/cli/reference/

## Current limitations (v0.1)

Native macOS and unit-test build still need a Mac machine or macOS GitHub
Actions runner for verification. There is no automated Claude setup because it
must not clobber an existing status line. No API-usage billing or synthetic
overall %; subscription quotas and API token accounting are separate.
