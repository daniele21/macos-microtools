#!/bin/bash
# Install a read-only RunnerPulse observer for the logged-in user.
# Never starts/stops GitHub runners and never invokes --force.
set -euo pipefail
HOME_DIR="$HOME"
INFRA="$HOME_DIR/Projects/local-runner-infra"
OBSERVER="$INFRA/scripts/runnerpulse_observer.py"
if [[ ! -f "$OBSERVER" ]]; then
  echo "Observer missing: $OBSERVER (update local-runner-infra first)" >&2
  exit 2
fi
if [[ -x /opt/homebrew/bin/python3 ]]; then
  PYTHON=/opt/homebrew/bin/python3
elif [[ -x /usr/local/bin/python3 ]]; then
  PYTHON=/usr/local/bin/python3
elif [[ -x /usr/bin/python3 ]]; then
  PYTHON=/usr/bin/python3
else
  echo "Python 3 not found" >&2
  exit 2
fi
"$PYTHON" -m py_compile "$OBSERVER"
LABEL=com.daniele.runnerpulse.observer
DEST_DIR="$HOME_DIR/Library/LaunchAgents"
DEST="$DEST_DIR/$LABEL.plist"
LOG_DIR="$HOME_DIR/Library/Logs/RunnerPulse"
mkdir -p "$DEST_DIR" "$LOG_DIR"
chmod 700 "$LOG_DIR"
"$PYTHON" - "$OBSERVER" "$INFRA" "$DEST" "$LOG_DIR" "$PYTHON" <<'PY'
import plistlib
from pathlib import Path
import sys
observer, infra, dest, logs, python = sys.argv[1:]
payload = {
    "Label": "com.daniele.runnerpulse.observer",
    "ProgramArguments": [python, observer, "--interval", "1"],
    "WorkingDirectory": infra,
    "EnvironmentVariables": {
        "HOME": str(Path.home()),
        "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        "PYTHONUNBUFFERED": "1",
    },
    "RunAtLoad": True,
    "KeepAlive": True,
    "ThrottleInterval": 20,
    "ProcessType": "Background",
    "LimitLoadToSessionType": "Aqua",
    "StandardOutPath": str(Path(logs) / "observer.log"),
    "StandardErrorPath": str(Path(logs) / "observer.err.log"),
}
with open(dest, "wb") as out:
    plistlib.dump(payload, out)
PY
chmod 600 "$DEST"
plutil -lint "$DEST"
DOMAIN="gui/$(id -u)"
if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
  launchctl bootout "$DOMAIN/$LABEL"
fi
launchctl bootstrap "$DOMAIN" "$DEST"
echo "RunnerPulse observer installed and started in $DOMAIN/$LABEL"
echo "Auto-start at user login enabled; GitHub runner services unchanged"
