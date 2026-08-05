#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
APP_NAME="RelayDock"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/support/Info.plist")"
DIST_DIR="$ROOT_DIR/dist"
APP_PATH="$DIST_DIR/$APP_NAME.app"
PKG_PATH="$DIST_DIR/$APP_NAME-$VERSION.pkg"
DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION.dmg"
CHECKSUM_PATH="$DIST_DIR/SHA256SUMS"
ZIP_PATH="$DIST_DIR/RelayDock-mac-universal.zip"
ZIP_CHECKSUM_PATH="$DIST_DIR/RelayDock-mac-universal.zip.sha256"
INSTALLER_IDENTITY="${RELAYDOCK_INSTALLER_SIGN_IDENTITY:-}"
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

rm -f "$PKG_PATH" "$DMG_PATH" "$ZIP_PATH" "$ZIP_CHECKSUM_PATH" "$CHECKSUM_PATH"
ditto --noextattr --norsrc "$APP_PATH" "$CLEAN_APP_PATH"
codesign --verify --deep --strict "$CLEAN_APP_PATH"

ZIP_STAGING_DIR="$PACKAGE_DIR/zip"
mkdir -p "$ZIP_STAGING_DIR"
ditto --noextattr --norsrc "$CLEAN_APP_PATH" "$ZIP_STAGING_DIR/$APP_NAME.app"
cp "$ROOT_DIR/scripts/local-sign-relaydock.sh" "$ZIP_STAGING_DIR/local-sign-relaydock.sh"
chmod 755 "$ZIP_STAGING_DIR/local-sign-relaydock.sh"
ditto -c -k --norsrc "$ZIP_STAGING_DIR" "$ZIP_PATH"

CREATE_PKG=0
if [[ -n "$INSTALLER_IDENTITY" ]] && \
   codesign -dv --verbose=4 "$CLEAN_APP_PATH" 2>&1 | grep -q "Authority=Developer ID Application"; then
    CREATE_PKG=1
    pkgbuild \
        --component "$CLEAN_APP_PATH" \
        --install-location "/Applications" \
        --identifier "app.relaydock.mac" \
        --version "$VERSION" \
        --scripts "$ROOT_DIR/support/pkg-scripts" \
        --sign "$INSTALLER_IDENTITY" \
        "$PKG_PATH"
fi

ditto --noextattr --norsrc "$APP_PATH" "$STAGING_DIR/$APP_NAME.app"
cp "$ROOT_DIR/scripts/install-relaydock.command" "$STAGING_DIR/Install RelayDock.command"
cp "$ROOT_DIR/scripts/uninstall-relaydock.command" "$STAGING_DIR/Uninstall RelayDock.command"
cp "$ROOT_DIR/scripts/local-sign-relaydock.sh" "$STAGING_DIR/local-sign-relaydock.sh"
cp "$ROOT_DIR/support/INSTALL.html" "$STAGING_DIR/安装说明.html"
cp "$ROOT_DIR/support/INSTALL_EN.html" "$STAGING_DIR/Install Guide.html"
ln -s /Applications "$STAGING_DIR/Applications"

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
if [[ "$CREATE_PKG" == "1" ]]; then
    CHECKSUM_FILES+=("$(basename "$PKG_PATH")")
fi
shasum -a 256 "${CHECKSUM_FILES[@]}" > "$CHECKSUM_PATH"

echo "Created release artifacts:"
echo "  $DMG_PATH"
if [[ "$CREATE_PKG" == "1" ]]; then
    echo "  $PKG_PATH"
fi
echo "  $ZIP_PATH"
echo "  $ZIP_CHECKSUM_PATH"
echo "  $CHECKSUM_PATH"

if [[ "$CREATE_PKG" == "0" ]]; then
    echo "Note: PKG creation was skipped. A PKG is emitted only when both the app"
    echo "and installer use Developer ID identities; use the DMG or one-line installer."
fi
