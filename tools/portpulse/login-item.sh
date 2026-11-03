#!/bin/bash
# Per-user, login-only, idempotent LaunchAgent for PortPulse. No sudo.
set -euo pipefail

LABEL="com.daniele.portpulse"
APP="$HOME/.local/opt/PortPulse.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
SERVICE="$DOMAIN/$LABEL"

xml_escape() {
  printf '%s' "$1" | sed -e 's/\&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"
}

render_plist() {
  local escaped_app
  escaped_app="$(xml_escape "$APP")"
  cat > "$1" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$LABEL</string>
<key>ProgramArguments</key><array>
  <string>/usr/bin/open</string><string>-g</string><string>-a</string><string>$escaped_app</string>
</array>
<key>RunAtLoad</key><true/>
<key>LimitLoadToSessionType</key><string>Aqua</string>
</dict></plist>
EOF
  plutil -lint "$1"
}

case "${1:-}" in
  enable)
    if [[ ! -x "$APP/Contents/MacOS/PortPulse" ]]; then
      echo "PortPulse not installed: $APP; run make install-portpulse first." >&2
      exit 2
    fi
    mkdir -p "$HOME/Library/LaunchAgents"
    tmp="$(mktemp "$PLIST.tmp.XXXXXX")"
    trap 'rm -f "$tmp"' EXIT
    render_plist "$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$PLIST"
    trap - EXIT
    launchctl bootout "$SERVICE" >/dev/null 2>&1 || true
    launchctl enable "$SERVICE"
    if ! launchctl bootstrap "$DOMAIN" "$PLIST"; then
      echo "Plist installed but could not bootstrap in current GUI; retry after login." >&2
      exit 1
    fi
    echo "PortPulse will open in the menu bar at each GUI login."
    ;;
  disable)
    launchctl bootout "$SERVICE" >/dev/null 2>&1 || true
    rm -f "$PLIST"
    echo "PortPulse auto-start disabled; currently running app not killed."
    ;;
  status)
    if [[ ! -f "$PLIST" ]]; then echo "PortPulse login: disabled."; exit 1; fi
    if launchctl print "$SERVICE" >/dev/null 2>&1; then
      echo "PortPulse login: configured and loaded."
    else
      echo "PortPulse login: plist present but not loaded."
      exit 2
    fi
    ;;
  render)
    [[ $# -eq 2 ]] || { echo "Usage: $0 render PATH" >&2; exit 2; }
    render_plist "$2"
    ;;
  *)
    echo "Usage: $0 {enable|disable|status|render PATH}" >&2
    exit 2
    ;;
esac
