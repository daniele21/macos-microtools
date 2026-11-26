#!/bin/bash
# Preserve Linux core-only tests while failing closed on native build errors.
set -euo pipefail
# Regression guard: standalone CLT can import SwiftUI but lack SwiftUIMacros.
# Do not reintroduce @State-dependent popover navigation.
if grep -nE '^[[:space:]]*@((SwiftUI\.)?State)([[:space:](]|$)' tools/llmpulse/llmpulse.swift; then
  echo "ERROR: LLMPulse must not depend on the SwiftUI State macro." >&2
  exit 1
fi
if [[ "$(uname -s)" == "Darwin" ]]; then
  xcode-select -p
  swiftc --version
  make -B build-llmpulse
  /usr/bin/plutil -lint bin/LLMPulse.app/Contents/Info.plist
  /usr/bin/codesign --verify --strict bin/LLMPulse.app
  bin/LLMPulse.app/Contents/MacOS/LLMPulse --test-menu-layout
fi
