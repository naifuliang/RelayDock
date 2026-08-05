#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
SOURCE_APP="$SCRIPT_DIR/RelayDock.app"
SIGNING_HELPER="$SCRIPT_DIR/local-sign-relaydock.sh"
TARGET_APP="/Applications/RelayDock.app"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/relaydock-install.XXXXXX")"
TEMP_APP="$WORK_DIR/RelayDock.app"
INSTALLING_APP="/Applications/.RelayDock.installing.$$"
BACKUP_APP="/Applications/.RelayDock.backup.$$"

cleanup() {
    /bin/rm -rf "$WORK_DIR" 2>/dev/null || true
    sudo rm -rf "$INSTALLING_APP" 2>/dev/null || true
    if [[ -d "$BACKUP_APP" && ! -e "$TARGET_APP" ]]; then
        sudo mv "$BACKUP_APP" "$TARGET_APP"
    fi
}

echo "RelayDock Local Installer"
echo ""
echo "This installer will:"
echo "  1. Copy RelayDock to /Applications"
echo "  2. Remove the download quarantine attribute from that copy"
echo "  3. Apply a stable RelayDock-only local code signature"
echo ""
echo "The local signing identity stays in RelayDock's private app-support folder"
echo "and is removed by the uninstaller. It is not a trusted root certificate."
read "REPLY?Continue? [y/N] "

if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
fi

if [[ ! -d "$SOURCE_APP" ]]; then
    echo "RelayDock.app was not found next to this installer."
    exit 1
fi

if ! codesign --verify --deep --strict --verbose=2 "$SOURCE_APP"; then
    echo "The RelayDock app in this DMG failed its integrity check. Installation stopped."
    exit 1
fi

IS_DEVELOPER_SIGNED=0
if codesign -dv --verbose=4 "$SOURCE_APP" 2>&1 | grep -q "Authority=Developer ID Application"; then
    spctl --assess --type execute --verbose=2 "$SOURCE_APP"
    IS_DEVELOPER_SIGNED=1
fi

trap cleanup EXIT
/usr/bin/ditto --noextattr --norsrc "$SOURCE_APP" "$TEMP_APP"

if [[ "$IS_DEVELOPER_SIGNED" == "1" ]]; then
    echo "Developer ID signature detected; preserving the vendor signature."
else
    if [[ ! -x "$SIGNING_HELPER" ]]; then
        echo "The local signing helper is missing. Installation stopped."
        exit 1
    fi
    /usr/bin/xattr -dr com.apple.quarantine "$TEMP_APP" 2>/dev/null || true
    "$SIGNING_HELPER" "$TEMP_APP"
fi

sudo codesign --verify --deep --strict --verbose=2 "$TEMP_APP"
sudo ditto --noextattr --norsrc "$TEMP_APP" "$INSTALLING_APP"

if [[ -e "$TARGET_APP" ]]; then
    echo "Replacing the existing /Applications/RelayDock.app…"
    sudo mv "$TARGET_APP" "$BACKUP_APP"
fi
sudo mv "$INSTALLING_APP" "$TARGET_APP"
sudo rm -rf "$BACKUP_APP" 2>/dev/null || true
/bin/rm -rf "$WORK_DIR"
trap - EXIT

echo "RelayDock was installed with a stable local signature."
open "$TARGET_APP"
