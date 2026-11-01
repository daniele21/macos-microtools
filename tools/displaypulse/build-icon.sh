#!/bin/bash
# Generate Finder/Login Items .icns from the chosen artwork with Apple sips + iconutil.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP="$ROOT/bin/DisplayPulse.app"
RESOURCE_DIR="$APP/Contents/Resources"
DEFAULT_SOURCE="$ROOT/tools/displaypulse/assets/DisplayPulse.webp"
SOURCE="${DISPLAYPULSE_ICON_SOURCE:-$DEFAULT_SOURCE}"
TARGET="$RESOURCE_DIR/DisplayPulse.icns"

[[ -f "$SOURCE" ]] || { echo "Missing DisplayPulse icon: $SOURCE" >&2; exit 2; }
mkdir -p "$RESOURCE_DIR"

# An optional full-res .icns can be used without lossy conversion.
if [[ "$SOURCE" == *.icns ]]; then
  [[ -s "$SOURCE" ]] || { echo "Empty icon: $SOURCE" >&2; exit 2; }
  if [[ "$SOURCE" != "$TARGET" ]]; then cp "$SOURCE" "$TARGET"; fi
  echo "DisplayPulse high-resolution .icns installed."
  exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/displaypulse-icon.XXXXXXXX")"
trap 'rm -rf "$WORK"' EXIT
ICONSET="$WORK/DisplayPulse.iconset"
mkdir -p "$ICONSET"

# The bundled artwork is a compact derivative of the user-selected image.
# For maximum sharpness set DISPLAYPULSE_ICON_SOURCE to the original PNG.
sips -s format png "$SOURCE" --out "$WORK/source.png" >/dev/null

for size in 16 32 64 128 256 512 1024; do
  sips -z "$size" "$size" "$WORK/source.png" \
    --out "$WORK/${size}.png" >/dev/null
done

cp "$WORK/16.png" "$ICONSET/icon_16x16.png"
cp "$WORK/32.png" "$ICONSET/icon_16x16@2x.png"
cp "$WORK/32.png" "$ICONSET/icon_32x32.png"
cp "$WORK/64.png" "$ICONSET/icon_32x32@2x.png"
cp "$WORK/128.png" "$ICONSET/icon_128x128.png"
cp "$WORK/256.png" "$ICONSET/icon_128x128@2x.png"
cp "$WORK/256.png" "$ICONSET/icon_256x256.png"
cp "$WORK/512.png" "$ICONSET/icon_256x256@2x.png"
cp "$WORK/512.png" "$ICONSET/icon_512x512.png"
cp "$WORK/1024.png" "$ICONSET/icon_512x512@2x.png"

iconutil -c icns "$ICONSET" -o "$TARGET"
[[ -s "$TARGET" ]] || { echo "Failed to produce .icns: $TARGET" >&2; exit 3; }
echo "DisplayPulse .icns generated: $TARGET"
