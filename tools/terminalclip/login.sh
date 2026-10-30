#!/usr/bin/env bash
set -euo pipefail
APP="$HOME/.local/opt/TerminalClip.app"
TARGET="$HOME/Library/LaunchAgents/com.terminalclip.local.plist"
LABEL="com.terminalclip.local"
case "$1" in
  enable)
    [[ -x "$APP/Contents/MacOS/TerminalClip" ]] || { echo "Installa prima TerminalClip con make install-terminalclip" >&2; exit 1; }
    mkdir -p "$HOME/Library/LaunchAgents"
    /usr/bin/python3 - "$TARGET" "$APP" <<'PY'
import plistlib, sys
path, app = sys.argv[1:]
with open(path, "wb") as f:
    plistlib.dump({"Label":"com.terminalclip.local", "ProgramArguments":[app+"/Contents/MacOS/TerminalClip"], "RunAtLoad":True, "KeepAlive":False}, f)
PY
    echo "Avvio automatico al prossimo login configurato."
    ;;
  disable)
    launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
    rm -f "$TARGET"
    echo "Avvio automatico disabilitato."
    ;;
  *) echo "Uso: bash tools/terminalclip/login.sh enable|disable" >&2; exit 2 ;;
esac
