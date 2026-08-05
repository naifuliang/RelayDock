#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
SOURCE_PNG="$ROOT_DIR/Assets/AppIcon.png"
OUTPUT_ICNS="$ROOT_DIR/support/RelayDock.icns"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/relaydock-icon.XXXXXX")"
ICONSET_DIR="$TEMP_DIR/RelayDock.iconset"

cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

"$ROOT_DIR/scripts/render-icon.swift" "$SOURCE_PNG"

mkdir -p "$ICONSET_DIR"

sips -z 16 16 "$SOURCE_PNG" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
sips -z 32 32 "$SOURCE_PNG" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$SOURCE_PNG" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
sips -z 64 64 "$SOURCE_PNG" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$SOURCE_PNG" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
sips -z 256 256 "$SOURCE_PNG" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$SOURCE_PNG" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
sips -z 512 512 "$SOURCE_PNG" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$SOURCE_PNG" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$SOURCE_PNG" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null

iconutil -c icns "$ICONSET_DIR" -o "$OUTPUT_ICNS"
if [[ ! -s "$OUTPUT_ICNS" ]]; then
    echo "iconutil did not produce a valid ICNS file" >&2
    exit 1
fi
echo "$OUTPUT_ICNS"
