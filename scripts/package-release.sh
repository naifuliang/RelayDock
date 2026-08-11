#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
APP_NAME="RelayDock"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/support/Info.plist")"
DIST_DIR="$ROOT_DIR/dist"
APP_PATH="$DIST_DIR/$APP_NAME.app"
DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION.dmg"
CHECKSUM_PATH="$DIST_DIR/SHA256SUMS"
ZIP_PATH="$DIST_DIR/RelayDock-mac-universal.zip"
ZIP_CHECKSUM_PATH="$DIST_DIR/RelayDock-mac-universal.zip.sha256"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/relaydock-dmg.XXXXXX")"
PACKAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/relaydock-pkg.XXXXXX")"
CLEAN_APP_PATH="$PACKAGE_DIR/$APP_NAME.app"
export COPYFILE_DISABLE=1

cleanup() {
    rm -rf "$STAGING_DIR"
    rm -rf "$PACKAGE_DIR"
}
trap cleanup EXIT

"$ROOT_DIR/scripts/build-app.sh" release

rm -f "$DMG_PATH" "$ZIP_PATH" "$ZIP_CHECKSUM_PATH" "$CHECKSUM_PATH"
ditto --noextattr --norsrc "$APP_PATH" "$CLEAN_APP_PATH"
codesign --verify --deep --strict "$CLEAN_APP_PATH"

ZIP_STAGING_DIR="$PACKAGE_DIR/zip"
mkdir -p "$ZIP_STAGING_DIR"
mkdir -p "$ZIP_STAGING_DIR/.payload"
ditto --noextattr --norsrc "$CLEAN_APP_PATH" "$ZIP_STAGING_DIR/.payload/$APP_NAME.app"
cp "$ROOT_DIR/scripts/local-sign-relaydock.sh" "$ZIP_STAGING_DIR/local-sign-relaydock.sh"
cp "$ROOT_DIR/scripts/install-relaydock.command" "$ZIP_STAGING_DIR/Install RelayDock.command"
cp "$ROOT_DIR/scripts/verify-signing-transition.sh" "$ZIP_STAGING_DIR/verify-signing-transition.sh"
chmod 755 "$ZIP_STAGING_DIR/local-sign-relaydock.sh"
chmod 755 "$ZIP_STAGING_DIR/Install RelayDock.command"
chmod 755 "$ZIP_STAGING_DIR/verify-signing-transition.sh"
ditto -c -k --norsrc "$ZIP_STAGING_DIR" "$ZIP_PATH"

mkdir -p "$STAGING_DIR/.payload"
ditto --noextattr --norsrc "$APP_PATH" "$STAGING_DIR/.payload/$APP_NAME.app"
# RelayDock 0.5.0's updater preflights a root-level RelayDock.app before it
# launches this release's installer. Keep a non-copy compatibility symlink so
# that old updater can validate the payload while every replacement still goes
# through Install RelayDock.command and its transactional identity checks.
ln -s ".payload/$APP_NAME.app" "$STAGING_DIR/$APP_NAME.app"
/usr/bin/SetFile -P -a V "$STAGING_DIR/$APP_NAME.app"
cp "$ROOT_DIR/scripts/install-relaydock.command" "$STAGING_DIR/Install RelayDock.command"
cp "$ROOT_DIR/scripts/uninstall-relaydock.command" "$STAGING_DIR/Uninstall RelayDock.command"
cp "$ROOT_DIR/scripts/local-sign-relaydock.sh" "$STAGING_DIR/local-sign-relaydock.sh"
cp "$ROOT_DIR/scripts/verify-signing-transition.sh" "$STAGING_DIR/verify-signing-transition.sh"
chmod 755 "$STAGING_DIR/verify-signing-transition.sh"
cp "$ROOT_DIR/support/INSTALL.html" "$STAGING_DIR/安装说明.html"
cp "$ROOT_DIR/support/INSTALL_EN.html" "$STAGING_DIR/Install Guide.html"

hdiutil create \
    -quiet \
    -ov \
    -format UDZO \
    -fs HFS+ \
    -volname "$APP_NAME $VERSION" \
    -srcfolder "$STAGING_DIR" \
    "$DMG_PATH"

cd "$DIST_DIR"
shasum -a 256 "$(basename "$ZIP_PATH")" > "$ZIP_CHECKSUM_PATH"
CHECKSUM_FILES=("$(basename "$DMG_PATH")" "$(basename "$ZIP_PATH")")
shasum -a 256 "${CHECKSUM_FILES[@]}" > "$CHECKSUM_PATH"

echo "Created release artifacts:"
echo "  $DMG_PATH"
echo "  $ZIP_PATH"
echo "  $ZIP_CHECKSUM_PATH"
echo "  $CHECKSUM_PATH"

echo "Note: PKG output is intentionally unsupported. Use the transactional DMG,"
echo "ZIP, or one-line installer so identity checks and rollback always run."
