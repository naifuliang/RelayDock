#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
SOURCE_APP="$SCRIPT_DIR/.payload/RelayDock.app"
SIGNING_HELPER="$SCRIPT_DIR/local-sign-relaydock.sh"
IDENTITY_POLICY="$SCRIPT_DIR/verify-signing-transition.sh"
SIGNING_ROOT="${RELAYDOCK_SIGNING_ROOT:-$HOME/Library/Application Support/RelayDock/Signing}"
PENDING_REPAIR_OLD="$SIGNING_ROOT/pending-repair-old-requirement"
PENDING_REPAIR_NEW="$SIGNING_ROOT/pending-repair-new-requirement"
APPROVED_DEVELOPER_IDENTITY="$SIGNING_ROOT/approved-developer-identity"
INSTALL_DIR="${RELAYDOCK_INSTALL_DIR:-/Applications}"
OPEN_APP="${RELAYDOCK_OPEN_APP:-1}"
INSTALL_CONFIRM="${RELAYDOCK_INSTALL_CONFIRM:-0}"
EXPECTED_VERSION="${RELAYDOCK_EXPECTED_VERSION:-}"
TEST_FAIL_AFTER_REPLACE="${RELAYDOCK_TEST_FAIL_AFTER_REPLACE:-0}"
TEST_FAIL_BEFORE_BACKUP="${RELAYDOCK_TEST_FAIL_BEFORE_BACKUP:-0}"
TARGET_APP="$INSTALL_DIR/RelayDock.app"
WORK_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/relaydock-install.XXXXXX")"
TEMP_APP="$WORK_DIR/RelayDock.app"
INSTALLING_APP="$INSTALL_DIR/.RelayDock.installing.$$"
BACKUP_APP="$INSTALL_DIR/.RelayDock.backup.$$"
LOCK_DIR="$INSTALL_DIR/.RelayDock.update.lock"
LOCK_ACQUIRED=0
SIGNING_IDENTITY_REPAIRED=0
EXISTING_REQUIREMENT=""
EXISTING_KIND="none"
EXISTING_IDENTITY=""
INCOMING_KIND="adhoc"
INCOMING_IDENTITY=""
HAD_EXISTING_APP=0
NEW_APP_INSTALLED=0
INSTALL_COMMITTED=0

read_terminal_response() {
    local prompt="$1"
    local terminal_fd
    local answer
    if ! exec {terminal_fd}<>/dev/tty 2>/dev/null; then
        echo "This approval requires an interactive Terminal. Installation stopped." >&2
        return 5
    fi
    /usr/bin/printf '%s' "$prompt" >&$terminal_fd
    if ! IFS= read -r answer <&$terminal_fd; then
        exec {terminal_fd}>&-
        echo "Could not read approval from the interactive Terminal. Installation stopped." >&2
        return 5
    fi
    exec {terminal_fd}>&-
    /usr/bin/printf '%s' "$answer"
}

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
    if [[ "$INSTALL_COMMITTED" != "1" && -d "$BACKUP_APP" ]]; then
        if [[ -e "$TARGET_APP" ]]; then
            run_install_command /bin/rm -rf "$TARGET_APP" 2>/dev/null || true
        fi
        run_install_command /bin/mv "$BACKUP_APP" "$TARGET_APP"
        echo "Installation failed; the previous RelayDock app was restored."
    elif [[ "$INSTALL_COMMITTED" != "1" && "$HAD_EXISTING_APP" == "0" \
            && "$NEW_APP_INSTALLED" == "1" && -e "$TARGET_APP" ]]; then
        run_install_command /bin/rm -rf "$TARGET_APP" 2>/dev/null || true
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
echo "The RelayDock-only signing identity stays in ~/Library/Keychains and is"
echo "used explicitly by the installer; it is removed by the uninstaller."
echo "It is not added to certificate trust and is not used for TLS."
if [[ "$INSTALL_CONFIRM" != "1" ]]; then
    if ! REPLY="$(read_terminal_response "Continue? [y/N] ")"; then
        exit 5
    fi
    if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
        echo "Cancelled."
        exit 2
    fi
fi

if [[ ! -d "$SOURCE_APP" ]]; then
    echo "RelayDock.app was not found next to this installer."
    exit 1
fi
if [[ ! -x "$IDENTITY_POLICY" ]]; then
    echo "The signing identity transition policy is missing. Installation stopped."
    exit 1
fi

if ! /usr/bin/codesign --verify --deep --strict --verbose=2 "$SOURCE_APP"; then
    echo "The RelayDock app in this DMG failed its integrity check. Installation stopped."
    exit 1
fi
SOURCE_IDENTIFIER="$(/usr/bin/codesign -dv --verbose=4 "$SOURCE_APP" 2>&1 | /usr/bin/sed -n 's/^Identifier=//p')"
if [[ "$SOURCE_IDENTIFIER" != "app.relaydock.mac" ]]; then
    echo "The installer payload has an unexpected bundle signing identifier."
    exit 4
fi
SOURCE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SOURCE_APP/Contents/Info.plist")"
if [[ -z "$EXPECTED_VERSION" ]]; then
    EXPECTED_VERSION="$SOURCE_VERSION"
elif [[ "$SOURCE_VERSION" != "$EXPECTED_VERSION" ]]; then
    echo "The installer expected RelayDock $EXPECTED_VERSION but contains $SOURCE_VERSION."
    exit 1
fi

IS_DEVELOPER_SIGNED=0
if /usr/bin/codesign -dv --verbose=4 "$SOURCE_APP" 2>&1 | /usr/bin/grep -q "Authority=Developer ID Application"; then
    /usr/sbin/spctl --assess --type execute --verbose=2 "$SOURCE_APP"
    IS_DEVELOPER_SIGNED=1
    INCOMING_KIND="developer"
    INCOMING_TEAM="$(/usr/bin/codesign -dv --verbose=4 "$SOURCE_APP" 2>&1 | /usr/bin/sed -n 's/^TeamIdentifier=//p')"
    if [[ -z "$INCOMING_TEAM" ]]; then
        echo "Developer ID app is missing a TeamIdentifier. Installation stopped."
        exit 4
    fi
    INCOMING_IDENTITY="$INCOMING_TEAM|$SOURCE_IDENTIFIER"
fi

if ! run_install_command /bin/mkdir "$LOCK_DIR"; then
    echo "Another RelayDock installation is already running."
    exit 3
fi
LOCK_ACQUIRED=1

if [[ -d "$TARGET_APP" ]] && /usr/bin/codesign --verify --deep --strict "$TARGET_APP" 2>/dev/null; then
    EXISTING_REQUIREMENT="$(/usr/bin/codesign -d -r- "$TARGET_APP" 2>&1 | /usr/bin/sed -n 's/^designated => //p')"
    if /usr/bin/codesign -dv --verbose=4 "$TARGET_APP" 2>&1 | /usr/bin/grep -q "Authority=Developer ID Application"; then
        EXISTING_KIND="developer"
        EXISTING_TEAM="$(/usr/bin/codesign -dv --verbose=4 "$TARGET_APP" 2>&1 | /usr/bin/sed -n 's/^TeamIdentifier=//p')"
        EXISTING_IDENTIFIER="$(/usr/bin/codesign -dv --verbose=4 "$TARGET_APP" 2>&1 | /usr/bin/sed -n 's/^Identifier=//p')"
        EXISTING_IDENTITY="$EXISTING_TEAM|$EXISTING_IDENTIFIER"
    elif [[ "$EXISTING_REQUIREMENT" == *'certificate root = H"'* ]]; then
        EXISTING_KIND="local"
        EXISTING_IDENTITY="$EXISTING_REQUIREMENT"
    else
        EXISTING_KIND="adhoc"
    fi
fi
/usr/bin/ditto --noextattr --norsrc "$SOURCE_APP" "$TEMP_APP"

if [[ "$IS_DEVELOPER_SIGNED" == "1" ]]; then
    echo "Developer ID signature detected; preserving the vendor signature."
else
    if [[ ! -x "$SIGNING_HELPER" ]]; then
        echo "The local signing helper is missing. Installation stopped."
        exit 1
    fi
    /usr/bin/xattr -dr com.apple.quarantine "$TEMP_APP" 2>/dev/null || true
    set +e
    "$SIGNING_HELPER" "$TEMP_APP"
    SIGNING_STATUS=$?
    set -e
    if [[ "$SIGNING_STATUS" == "4" ]]; then
        echo ""
        echo "RelayDock's previous local signing identity is incomplete or unusable."
        echo "Repair keeps the damaged material in RelayDock/Signing/Recovery and"
        echo "creates a new identity. Existing API keys remain in the login Keychain;"
        echo "RelayDock will offer an explicit one-time credential migration."
        if ! REPAIR_REPLY="$(read_terminal_response "Repair the signing identity and continue? [y/N] ")"; then
            exit 5
        fi
        if [[ ! "$REPAIR_REPLY" =~ ^[Yy]$ ]]; then
            echo "Installation stopped without replacing RelayDock."
            exit 4
        fi
        /bin/mkdir -p "$SIGNING_ROOT"
        /bin/chmod 700 "$SIGNING_ROOT"
        /usr/bin/printf '%s' "$EXISTING_REQUIREMENT" > "$PENDING_REPAIR_OLD"
        /bin/chmod 600 "$PENDING_REPAIR_OLD"
        /bin/rm -f "$PENDING_REPAIR_NEW"
        RELAYDOCK_REPAIR_SIGNING_IDENTITY=1 "$SIGNING_HELPER" "$TEMP_APP"
        SIGNING_IDENTITY_REPAIRED=1
    elif [[ "$SIGNING_STATUS" != "0" ]]; then
        exit "$SIGNING_STATUS"
    fi
fi

/usr/bin/codesign --verify --deep --strict --verbose=2 "$TEMP_APP"
NEW_REQUIREMENT="$(/usr/bin/codesign -d -r- "$TEMP_APP" 2>&1 | /usr/bin/sed -n 's/^designated => //p')"
if [[ "$IS_DEVELOPER_SIGNED" == "0" ]]; then
    if [[ -z "$NEW_REQUIREMENT" || "$NEW_REQUIREMENT" != *'certificate root = H"'* ]]; then
        echo "The installed build does not have a certificate-bound designated requirement."
        echo "Installation stopped before replacing the existing application."
        exit 4
    fi
    INCOMING_KIND="local"
    INCOMING_IDENTITY="$NEW_REQUIREMENT"
fi
REPAIR_ALLOWED="$SIGNING_IDENTITY_REPAIRED"
DEVELOPER_ADOPTION_ALLOWED=0
if [[ -f "$PENDING_REPAIR_OLD" && "$(<"$PENDING_REPAIR_OLD")" == "$EXISTING_REQUIREMENT" ]]; then
    if [[ -f "$PENDING_REPAIR_NEW" ]]; then
        [[ "$(<"$PENDING_REPAIR_NEW")" == "$NEW_REQUIREMENT" ]] && REPAIR_ALLOWED=1
    else
        /usr/bin/printf '%s' "$NEW_REQUIREMENT" > "$PENDING_REPAIR_NEW"
        /bin/chmod 600 "$PENDING_REPAIR_NEW"
        REPAIR_ALLOWED=1
    fi
fi
if [[ "$EXISTING_KIND" == "local" && "$INCOMING_KIND" == "developer" ]]; then
    if [[ -f "$APPROVED_DEVELOPER_IDENTITY" ]]; then
        if [[ "$(<"$APPROVED_DEVELOPER_IDENTITY")" == "$INCOMING_IDENTITY" ]]; then
            DEVELOPER_ADOPTION_ALLOWED=1
        else
            echo "This Developer ID identity does not match the previously approved RelayDock vendor."
            echo "Installation stopped before replacing the existing application."
            exit 4
        fi
    else
        echo ""
        echo "RelayDock is changing from its private local signature to Developer ID."
        echo "Incoming Team ID and bundle identifier: $INCOMING_IDENTITY"
        echo "This approval is permanent; later updates must use this exact identity."
        if ! ADOPTION_REPLY="$(read_terminal_response "Type the Team ID ($INCOMING_TEAM) to approve this vendor: ")"; then
            exit 5
        fi
        if [[ "$ADOPTION_REPLY" != "$INCOMING_TEAM" ]]; then
            echo "Developer ID adoption was not approved. Installation stopped."
            exit 4
        fi
        /bin/mkdir -p "$SIGNING_ROOT"
        /bin/chmod 700 "$SIGNING_ROOT"
        ADOPTION_TEMP="$SIGNING_ROOT/.approved-developer-identity.$$"
        /usr/bin/printf '%s' "$INCOMING_IDENTITY" > "$ADOPTION_TEMP"
        /bin/chmod 600 "$ADOPTION_TEMP"
        /bin/mv "$ADOPTION_TEMP" "$APPROVED_DEVELOPER_IDENTITY"
        DEVELOPER_ADOPTION_ALLOWED=1
    fi
fi
if ! "$IDENTITY_POLICY" "$EXISTING_KIND" "$EXISTING_IDENTITY" \
    "$INCOMING_KIND" "$INCOMING_IDENTITY" "$REPAIR_ALLOWED" \
    "$DEVELOPER_ADOPTION_ALLOWED"; then
    echo "The update would change RelayDock's signing identity and invalidate Keychain access."
    echo "Installation stopped before replacing the existing application."
    exit 4
fi
run_install_command /usr/bin/ditto --noextattr --norsrc "$TEMP_APP" "$INSTALLING_APP"

if [[ -e "$TARGET_APP" ]]; then
    HAD_EXISTING_APP=1
    echo "Replacing the existing $TARGET_APP…"
    if [[ "$TEST_FAIL_BEFORE_BACKUP" == "1" ]]; then
        echo "Injected pre-backup failure."
        exit 8
    fi
    run_install_command /bin/mv "$TARGET_APP" "$BACKUP_APP"
fi
run_install_command /bin/mv "$INSTALLING_APP" "$TARGET_APP"
NEW_APP_INSTALLED=1
if [[ "$TEST_FAIL_AFTER_REPLACE" == "1" ]]; then
    echo "Injected post-replacement verification failure."
    exit 9
fi
/usr/bin/codesign --verify --deep --strict --verbose=2 "$TARGET_APP"
INSTALLED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$TARGET_APP/Contents/Info.plist")"
if [[ "$INSTALLED_VERSION" != "$EXPECTED_VERSION" ]]; then
    echo "Installed version verification failed: expected $EXPECTED_VERSION, found $INSTALLED_VERSION."
    exit 1
fi
INSTALLED_REQUIREMENT="$(/usr/bin/codesign -d -r- "$TARGET_APP" 2>&1 | /usr/bin/sed -n 's/^designated => //p')"
if [[ "$INSTALLED_REQUIREMENT" != "$NEW_REQUIREMENT" ]]; then
    echo "Installed signing requirement verification failed."
    exit 4
fi
INSTALL_COMMITTED=1
/bin/rm -f "$PENDING_REPAIR_OLD" "$PENDING_REPAIR_NEW"
run_install_command /bin/rm -rf "$BACKUP_APP" 2>/dev/null || true
/bin/rm -rf "$WORK_DIR"
run_install_command /bin/rm -rf "$LOCK_DIR"
LOCK_ACQUIRED=0
trap - EXIT

echo "RelayDock was installed with a stable local signature."
if [[ "$OPEN_APP" == "1" ]]; then
    /usr/bin/open "$TARGET_APP"
fi
