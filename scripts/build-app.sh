#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
APP_NAME="RelayDock"
BUILD_CONFIG="${1:-release}"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
SIGN_IDENTITY="${RELAYDOCK_APP_SIGN_IDENTITY:--}"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/relaydock-app.XXXXXX")"
TEMP_APP="$TEMP_DIR/$APP_NAME.app"

cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

cd "$ROOT_DIR"
swift build --disable-sandbox -c "$BUILD_CONFIG" --triple arm64-apple-macosx13.0
swift build --disable-sandbox -c "$BUILD_CONFIG" --triple x86_64-apple-macosx13.0
"$ROOT_DIR/scripts/build-icon.sh"

mkdir -p "$TEMP_APP/Contents/MacOS" "$TEMP_APP/Contents/Resources"
lipo -create \
    "$ROOT_DIR/.build/arm64-apple-macosx/$BUILD_CONFIG/$APP_NAME" \
    "$ROOT_DIR/.build/x86_64-apple-macosx/$BUILD_CONFIG/$APP_NAME" \
    -output "$TEMP_APP/Contents/MacOS/$APP_NAME"
cp "$ROOT_DIR/support/Info.plist" "$TEMP_APP/Contents/Info.plist"
cp "$ROOT_DIR/support/RelayDock.icns" "$TEMP_APP/Contents/Resources/RelayDock.icns"
codesign --force --deep --options runtime --sign "$SIGN_IDENTITY" "$TEMP_APP"

mkdir -p "$ROOT_DIR/dist"
rm -rf "$APP_DIR"
mv "$TEMP_APP" "$APP_DIR"

echo "$APP_DIR"
