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

rm -f "$PKG_PATH" "$DMG_PATH" "$CHECKSUM_PATH"
ditto --noextattr --norsrc "$APP_PATH" "$CLEAN_APP_PATH"
codesign --verify --deep --strict "$CLEAN_APP_PATH"

PKG_ARGUMENTS=(
    --component "$CLEAN_APP_PATH"
    --install-location "/Applications"
    --identifier "app.relaydock.mac"
    --version "$VERSION"
    --scripts "$ROOT_DIR/support/pkg-scripts"
)

if [[ -n "$INSTALLER_IDENTITY" ]]; then
    PKG_ARGUMENTS+=(--sign "$INSTALLER_IDENTITY")
fi

pkgbuild "${PKG_ARGUMENTS[@]}" "$PKG_PATH"

ditto --noextattr --norsrc "$APP_PATH" "$STAGING_DIR/$APP_NAME.app"
cp "$ROOT_DIR/scripts/install-relaydock.command" "$STAGING_DIR/Install RelayDock.command"
cp "$ROOT_DIR/scripts/uninstall-relaydock.command" "$STAGING_DIR/Uninstall RelayDock.command"
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
shasum -a 256 "$(basename "$DMG_PATH")" "$(basename "$PKG_PATH")" > "$CHECKSUM_PATH"

echo "Created release artifacts:"
echo "  $DMG_PATH"
echo "  $PKG_PATH"
echo "  $CHECKSUM_PATH"

if [[ "$INSTALLER_IDENTITY" == "" ]]; then
    echo "Note: no Developer ID Installer identity was found/configured; the PKG is unsigned."
fi
