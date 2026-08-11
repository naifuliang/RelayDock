#!/bin/zsh
set -euo pipefail

APP_NAME="RelayDock"
INSTALL_DIR="${RELAYDOCK_INSTALL_DIR:-/Applications}"
OPEN_APP="${RELAYDOCK_OPEN_APP:-1}"
RELEASE_BASE="${RELAYDOCK_RELEASE_BASE_URL:-https://github.com/naifuliang/RelayDock/releases/latest/download}"
ARCHIVE_URL="${RELAYDOCK_ARCHIVE_URL:-$RELEASE_BASE/RelayDock-mac-universal.zip}"
CHECKSUM_URL="${RELAYDOCK_CHECKSUM_URL:-$RELEASE_BASE/RelayDock-mac-universal.zip.sha256}"
WORK_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/relaydock-install.XXXXXX")"
ARCHIVE_PATH="$WORK_DIR/RelayDock-mac-universal.zip"
CHECKSUM_PATH="$WORK_DIR/RelayDock-mac-universal.zip.sha256"

cleanup() { /bin/rm -rf "$WORK_DIR"; }
trap cleanup EXIT INT TERM

echo "RelayDock installer"
echo ""
echo "This installer downloads the latest RelayDock release from GitHub,"
echo "verifies its SHA-256 checksum, then hands off to the same transactional"
echo "installer used by the DMG and in-app updater."
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
if ! /usr/bin/printf '%s\n' "$EXPECTED_HASH" | /usr/bin/grep -Eq '^[[:xdigit:]]{64}$'; then
    echo "The release checksum file is invalid. Installation stopped."
    exit 1
fi
ACTUAL_HASH="$(/usr/bin/shasum -a 256 "$ARCHIVE_PATH" | /usr/bin/awk '{ print $1 }')"
if [[ "${ACTUAL_HASH:l}" != "${EXPECTED_HASH:l}" ]]; then
    echo "The downloaded archive failed its SHA-256 check. Installation stopped."
    exit 1
fi

/usr/bin/ditto -x -k "$ARCHIVE_PATH" "$WORK_DIR/unpacked"
INSTALLER="$WORK_DIR/unpacked/Install RelayDock.command"
if [[ ! -x "$INSTALLER" || ! -d "$WORK_DIR/unpacked/.payload/$APP_NAME.app" \
      || ! -x "$WORK_DIR/unpacked/local-sign-relaydock.sh" \
      || ! -x "$WORK_DIR/unpacked/verify-signing-transition.sh" ]]; then
    echo "The downloaded archive is missing a verified RelayDock installer component."
    exit 1
fi

RELAYDOCK_INSTALL_DIR="$INSTALL_DIR" \
RELAYDOCK_OPEN_APP="$OPEN_APP" \
RELAYDOCK_INSTALL_CONFIRM=1 \
    /bin/zsh "$INSTALLER"
