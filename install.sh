#!/bin/zsh
set -euo pipefail

APP_NAME="RelayDock"
INSTALL_DIR="${RELAYDOCK_INSTALL_DIR:-/Applications}"
TARGET_APP="$INSTALL_DIR/$APP_NAME.app"
OPEN_APP="${RELAYDOCK_OPEN_APP:-1}"
RELEASE_BASE="${RELAYDOCK_RELEASE_BASE_URL:-https://github.com/naifuliang/RelayDock/releases/latest/download}"
ARCHIVE_URL="${RELAYDOCK_ARCHIVE_URL:-$RELEASE_BASE/RelayDock-mac-universal.zip}"
CHECKSUM_URL="${RELAYDOCK_CHECKSUM_URL:-$RELEASE_BASE/RelayDock-mac-universal.zip.sha256}"
WORK_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/relaydock-install.XXXXXX")"
ARCHIVE_PATH="$WORK_DIR/RelayDock-mac-universal.zip"
CHECKSUM_PATH="$WORK_DIR/RelayDock-mac-universal.zip.sha256"
STAGED_APP="$WORK_DIR/$APP_NAME.app"
INSTALLING_APP="$INSTALL_DIR/.$APP_NAME.installing.$$"
BACKUP_APP="$INSTALL_DIR/.$APP_NAME.backup.$$"
INSTALL_STARTED=0
INSTALL_COMPLETE=0

cleanup() {
    EXIT_STATUS=$?
    trap - EXIT INT TERM
    set +e
    if [[ "$INSTALL_STARTED" == "1" && "$INSTALL_COMPLETE" != "1" ]]; then
        if [[ -e "$BACKUP_APP" && ! -e "$TARGET_APP" ]]; then
            run_install_command /bin/mv "$BACKUP_APP" "$TARGET_APP"
        elif [[ -e "$BACKUP_APP" && -e "$TARGET_APP" ]]; then
            run_install_command /bin/rm -rf "$BACKUP_APP"
        fi
        if [[ -e "$INSTALLING_APP" ]]; then
            run_install_command /bin/rm -rf "$INSTALLING_APP"
        fi
    fi
    /bin/rm -rf "$WORK_DIR"
    exit "$EXIT_STATUS"
}
trap cleanup EXIT INT TERM

run_install_command() {
    if [[ -w "$INSTALL_DIR" ]]; then
        "$@"
    else
        /usr/bin/sudo "$@"
    fi
}

echo "RelayDock installer"
echo ""
echo "This installer downloads the latest RelayDock release from GitHub,"
echo "checks its SHA-256 checksum and existing app signature for integrity,"
echo "then installs it in $INSTALL_DIR. These checks are not Apple notarization."
echo "It does not disable Gatekeeper globally, install a certificate, or change the system proxy."
echo "For this unsigned test build, it removes quarantine only from the installed"
echo "RelayDock copy and applies a local ad-hoc signature."
echo ""
read "REPLY?Continue? [y/N] " </dev/tty

if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
fi

echo "Downloading RelayDock…"
/usr/bin/curl --fail --silent --show-error --location "$ARCHIVE_URL" --output "$ARCHIVE_PATH"
/usr/bin/curl --fail --silent --show-error --location "$CHECKSUM_URL" --output "$CHECKSUM_PATH"

EXPECTED_HASH="$(/usr/bin/awk 'NF { print $1; exit }' "$CHECKSUM_PATH")"
if ! printf '%s\n' "$EXPECTED_HASH" | /usr/bin/grep -Eq '^[[:xdigit:]]{64}$'; then
    echo "The release checksum file is invalid. Installation stopped."
    exit 1
fi

ACTUAL_HASH="$(/usr/bin/shasum -a 256 "$ARCHIVE_PATH" | /usr/bin/awk '{ print $1 }')"
if [[ "${ACTUAL_HASH:l}" != "${EXPECTED_HASH:l}" ]]; then
    echo "The downloaded archive failed its SHA-256 check. Installation stopped."
    exit 1
fi

/usr/bin/ditto -x -k "$ARCHIVE_PATH" "$WORK_DIR/unpacked"
SOURCE_APP="$WORK_DIR/unpacked/$APP_NAME.app"
if [[ ! -d "$SOURCE_APP" ]]; then
    echo "The downloaded archive does not contain $APP_NAME.app. Installation stopped."
    exit 1
fi

/usr/bin/codesign --verify --deep --strict --verbose=2 "$SOURCE_APP"
/usr/bin/ditto --noextattr --norsrc "$SOURCE_APP" "$STAGED_APP"

if /usr/bin/codesign -dv --verbose=4 "$SOURCE_APP" 2>&1 | /usr/bin/grep -q "Authority=Developer ID Application"; then
    echo "Developer ID signature detected; preserving the vendor signature."
    /usr/sbin/spctl --assess --type execute --verbose=2 "$STAGED_APP"
else
    /usr/bin/xattr -dr com.apple.quarantine "$STAGED_APP" 2>/dev/null || true
    /usr/bin/codesign --force --deep --options runtime --sign - "$STAGED_APP"
fi

/usr/bin/codesign --verify --deep --strict --verbose=2 "$STAGED_APP"

echo "Installing RelayDock in $INSTALL_DIR…"
INSTALL_STARTED=1
run_install_command /bin/rm -rf "$INSTALLING_APP" "$BACKUP_APP"
run_install_command /usr/bin/ditto --noextattr --norsrc "$STAGED_APP" "$INSTALLING_APP"

if [[ -e "$TARGET_APP" ]]; then
    run_install_command /bin/mv "$TARGET_APP" "$BACKUP_APP"
fi

if ! run_install_command /bin/mv "$INSTALLING_APP" "$TARGET_APP"; then
    if [[ -e "$BACKUP_APP" && ! -e "$TARGET_APP" ]]; then
        run_install_command /bin/mv "$BACKUP_APP" "$TARGET_APP"
    fi
    echo "Installation failed; the previous copy was restored."
    exit 1
fi

run_install_command /bin/rm -rf "$BACKUP_APP"
INSTALL_COMPLETE=1
if [[ "$OPEN_APP" == "1" ]]; then
    /usr/bin/open "$TARGET_APP"
fi
echo "RelayDock was installed successfully."
