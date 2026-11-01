#!/bin/bash
# DisplayPulse login startup for the current logged-in macOS user.
# No sudo, no system-wide LaunchDaemons, no persistent background shell.
set -euo pipefail

LABEL="com.daniele.displaypulse"
APP="$HOME/.local/opt/DisplayPulse.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
SERVICE="$DOMAIN/$LABEL"

xml_escape() {
  printf '%s' "$1" | sed \
    -e 's/\&/\&amp;/g' \
    -e 's/</\&lt;/g' \
    -e 's/>/\&gt;/g' \
    -e 's/"/\&quot;/g' \
    -e "s/'/\&apos;/g"
}

render_plist() {
  local output="$1"
  local escaped_app
  escaped_app="$(xml_escape "$APP")"
  cat > "$output" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/open</string>
    <string>-g</string>
    <string>-a</string>
    <string>$escaped_app</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>LimitLoadToSessionType</key>
  <string>Aqua</string>
</dict>
</plist>
EOF
  plutil -lint "$output"
}

case "${1:-}" in
  enable)
    if [[ ! -x "$APP/Contents/MacOS/DisplayPulse" ]]; then
      echo "DisplayPulse not installed at: $APP" >&2
      echo "First run: make install-displaypulse" >&2
      exit 2
    fi
    mkdir -p "$HOME/Library/LaunchAgents"
    tmp="$(mktemp "$PLIST.tmp.XXXXXX")"
    trap 'rm -f "$tmp"' EXIT
    render_plist "$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$PLIST"
    trap - EXIT

    # Idempotent: replace only our own job, never other login agents.
    launchctl bootout "$SERVICE" >/dev/null 2>&1 || true
    launchctl enable "$SERVICE"
    if ! launchctl bootstrap "$DOMAIN" "$PLIST"; then
      echo "Could not activate in this GUI session. Plist installed for next login." >&2
      echo "Check System Settings > General > Login Items & Extensions." >&2
      exit 1
    fi
    echo "DisplayPulse auto-start enabled for the current user's GUI login."
    echo "The macOS menu bar app is opened now and at every future login."
    ;;
  disable)
    launchctl bootout "$SERVICE" >/dev/null 2>&1 || true
    rm -f "$PLIST"
    echo "DisplayPulse auto-start disabled. The running app, if any, is untouched."
    ;;
  status)
    if [[ ! -f "$PLIST" ]]; then
      echo "DisplayPulse login: disabled (no LaunchAgent installed)."
      exit 1
    fi
    if launchctl print "$SERVICE" >/dev/null 2>&1; then
      echo "DisplayPulse login: configured and loaded ($SERVICE)."
    else
      echo "DisplayPulse login: plist exists, not loaded in this GUI session."
      echo "The app may start at the next login; inspect macOS Login Items settings."
      exit 2
    fi
    ;;
  render)
    # Non-invasive CI test: generates a valid plist without changing the user's login.
    if [[ $# -ne 2 ]]; then
      echo "Usage: $0 render /path/to/test.plist" >&2
      exit 2
    fi
    render_plist "$2"
    ;;
  *)
    echo "Usage: $0 {enable|disable|status|render OUTPUT}" >&2
    exit 2
    ;;
esac
