#!/bin/bash
# LaunchServices checks Mach-O LC_BUILD_VERSION, not just LSMinimumSystemVersion.
set -euo pipefail

app="$1"
plist="$app/Contents/Info.plist"
expected="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$plist")"

for executable in LLMPulse LLMPulseIngest; do
  binary="$app/Contents/MacOS/$executable"
  if [[ ! -x "$binary" ]]; then
    echo "ERROR: missing executable $binary" >&2
    exit 1
  fi
  minos="$(/usr/bin/xcrun vtool -show-build "$binary" | /usr/bin/awk '$1 == "minos" { print $2; exit }')"
  if [[ -z "$minos" || "$minos" != "$expected" ]]; then
    echo "ERROR: $executable Mach-O minos '$minos' does not match Info.plist minimum '$expected'." >&2
    echo "Run: make -B build-llmpulse" >&2
    exit 1
  fi
done

echo "✓ LLMPulse and LLMPulseIngest Mach-O minimum macOS $expected"
