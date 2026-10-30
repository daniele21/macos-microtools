#!/usr/bin/env bash
set -e

# macOS Micro-Tools Installer
PREFIX="${HOME}/.local/bin"
mkdir -p "${PREFIX}"

echo "==> Building MenuMeter..."
swiftc -O tools/menumeter/menumeter.swift -o "${PREFIX}/menumeter"
cp tools/menumeter/menumeter.swift "${PREFIX}/menumeter.swift"

echo "✓ MenuMeter installed to ${PREFIX}/menumeter"

if [[ ":$PATH:" != *":${PREFIX}:"* ]]; then
    echo ""
    echo "⚠️  Note: ${PREFIX} is not in your PATH."
    echo "   Add this line to your ~/.zshrc:"
    echo '   export PATH="$HOME/.local/bin:$PATH"'
fi

echo ""
echo "To launch MenuMeter now:"
echo "  ${PREFIX}/menumeter &"

