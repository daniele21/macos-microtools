#!/usr/bin/env bash
set -e

# macOS Micro-Tools Installer
PREFIX="${HOME}/.local/bin"
mkdir -p "${PREFIX}"

echo "==> Building MenuMeter..."
swiftc -O tools/menumeter/menumeter.swift -o "${PREFIX}/menumeter"
cp tools/menumeter/menumeter.swift "${PREFIX}/menumeter.swift"

echo "✓ MenuMeter installed to ${PREFIX}/menumeter"

echo "==> Building TerminalClip..."
mkdir -p "$HOME/.local/opt/TerminalClip.app/Contents/MacOS"
swiftc -O -framework AppKit -framework ApplicationServices -framework Carbon \
  tools/terminalclip/terminalclip.swift \
  -o "$HOME/.local/opt/TerminalClip.app/Contents/MacOS/TerminalClip"
cp tools/terminalclip/Info.plist "$HOME/.local/opt/TerminalClip.app/Contents/Info.plist"
codesign --force --sign - "$HOME/.local/opt/TerminalClip.app" || true
echo "✓ TerminalClip installed to $HOME/.local/opt/TerminalClip.app"

if [[ ":$PATH:" != *":${PREFIX}:"* ]]; then
    echo ""
    echo "⚠️  Note: ${PREFIX} is not in your PATH."
    echo "   Add this line to your ~/.zshrc:"
    echo '   export PATH="$HOME/.local/bin:$PATH"'
fi

echo ""
echo "To launch MenuMeter now:"
echo "  ${PREFIX}/menumeter &"


echo 'To launch TerminalClip: open "$HOME/.local/opt/TerminalClip.app"'
