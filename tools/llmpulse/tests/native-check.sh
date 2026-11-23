#!/bin/bash
# Preserve Linux core-only tests while failing closed on native build errors.
set -euo pipefail
if [[ "$(uname -s)" == "Darwin" ]]; then
  make -B build-llmpulse
  /usr/bin/plutil -lint bin/LLMPulse.app/Contents/Info.plist
  /usr/bin/codesign --verify --strict bin/LLMPulse.app
fi
