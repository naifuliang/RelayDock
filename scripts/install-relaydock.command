#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
SOURCE_APP="$SCRIPT_DIR/RelayDock.app"
SIGNING_HELPER="$SCRIPT_DIR/local-sign-relaydock.sh"
INSTALL_DIR="${RELAYDOCK_INSTALL_DIR:-/Applications}"
OPEN_APP="${RELAYDOCK_OPEN_APP:-1}"
TARGET_APP="$INSTALL_DIR/RelayDock.app"
WORK_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/relaydock-install.XXXXXX")"
TEMP_APP="$WORK_DIR/RelayDock.app"
INSTALLING_APP="$INSTALL_DIR/.RelayDock.installing.$$"
BACKUP_APP="$INSTALL_DIR/.RelayDock.backup.$$"
LOCK_DIR="$INSTALL_DIR/.RelayDock.update.lock"
LOCK_ACQUIRED=0

run_install_command() {
    if [[ -w "$INSTALL_DIR" ]]; then
        "$@"
    else
        /usr/bin/sudo "$@"
    fi
}

cleanup() {
    /bin/rm -rf "$WORK_DIR" 2>/dev/null || true
    if [[ -e "$INSTALLING_APP" ]]; then
        run_install_command /bin/rm -rf "$INSTALLING_APP" 2>/dev/null || true
    fi
    if [[ -d "$BACKUP_APP" && ! -e "$TARGET_APP" ]]; then
        run_install_command /bin/mv "$BACKUP_APP" "$TARGET_APP"
    fi
    if [[ "$LOCK_ACQUIRED" == "1" ]]; then
        run_install_command /bin/rm -rf "$LOCK_DIR" 2>/dev/null || true
    fi
}

trap cleanup EXIT

echo "RelayDock Local Installer"
echo ""
echo "This installer will:"
echo "  1. Copy RelayDock to $INSTALL_DIR"
echo "  2. Remove the download quarantine attribute from that copy"
echo "  3. Apply a stable RelayDock-only local code signature"
echo ""
echo "The RelayDock-only signing identity stays in ~/Library/Keychains, is added"
echo "only to your Keychain search list, and is removed by the uninstaller."
echo "It is not added to certificate trust and is not used for TLS."
read "REPLY?Continue? [y/N] "

if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 2
fi

if [[ ! -d "$SOURCE_APP" ]]; then
    echo "RelayDock.app was not found next to this installer."
    exit 1
fi

if ! /usr/bin/codesign --verify --deep --strict --verbose=2 "$SOURCE_APP"; then
    echo "The RelayDock app in this DMG failed its integrity check. Installation stopped."
    exit 1
fi

IS_DEVELOPER_SIGNED=0
if /usr/bin/codesign -dv --verbose=4 "$SOURCE_APP" 2>&1 | /usr/bin/grep -q "Authority=Developer ID Application"; then
    /usr/sbin/spctl --assess --type execute --verbose=2 "$SOURCE_APP"
    IS_DEVELOPER_SIGNED=1
fi

if ! run_install_command /bin/mkdir "$LOCK_DIR"; then
    echo "Another RelayDock installation is already running."
    exit 3
fi
LOCK_ACQUIRED=1
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

/usr/bin/codesign --verify --deep --strict --verbose=2 "$TEMP_APP"
run_install_command /usr/bin/ditto --noextattr --norsrc "$TEMP_APP" "$INSTALLING_APP"

if [[ -e "$TARGET_APP" ]]; then
    echo "Replacing the existing $TARGET_APP…"
    run_install_command /bin/mv "$TARGET_APP" "$BACKUP_APP"
fi
run_install_command /bin/mv "$INSTALLING_APP" "$TARGET_APP"
run_install_command /bin/rm -rf "$BACKUP_APP" 2>/dev/null || true
/bin/rm -rf "$WORK_DIR"
run_install_command /bin/rm -rf "$LOCK_DIR"
LOCK_ACQUIRED=0
trap - EXIT

echo "RelayDock was installed with a stable local signature."
if [[ "$OPEN_APP" == "1" ]]; then
    /usr/bin/open "$TARGET_APP"
fi
