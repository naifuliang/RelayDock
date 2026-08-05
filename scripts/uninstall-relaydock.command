#!/bin/zsh
set -euo pipefail

APP_PATH="/Applications/RelayDock.app"
USER_APP_PATH="$HOME/Applications/RelayDock.app"

echo "RelayDock Uninstaller"
echo "This removes RelayDock, its preferences, generated OpenCode files, saved endpoint API keys,"
echo "and its private local code-signing keychain."
read "REPLY?Continue? [y/N] "

if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
fi

/usr/bin/pkill -x RelayDock 2>/dev/null || true

if [[ -e "$APP_PATH" ]]; then
    /usr/bin/sudo /bin/rm -rf "$APP_PATH"
fi

if [[ -e "$USER_APP_PATH" ]]; then
    /bin/rm -rf "$USER_APP_PATH"
fi

/usr/bin/defaults delete app.relaydock.mac 2>/dev/null || true
SIGNING_KEYCHAIN="$HOME/Library/Keychains/RelayDockLocalSigning.keychain-db"
USER_KEYCHAINS=("${(@f)$(/usr/bin/security list-keychains -d user | /usr/bin/sed -e 's/^[[:space:]]*"//' -e 's/"$//')}")
REMAINING_KEYCHAINS=()
for KEYCHAIN in "${USER_KEYCHAINS[@]}"; do
    if [[ -n "$KEYCHAIN" && "$KEYCHAIN" != "$SIGNING_KEYCHAIN" ]]; then
        REMAINING_KEYCHAINS+=("$KEYCHAIN")
    fi
done
if (( ${#REMAINING_KEYCHAINS[@]} > 0 )); then
    /usr/bin/security list-keychains -d user -s "${REMAINING_KEYCHAINS[@]}" 2>/dev/null || true
fi
/usr/bin/security delete-keychain "$SIGNING_KEYCHAIN" >/dev/null 2>&1 || true
/bin/rm -f "$SIGNING_KEYCHAIN"
/bin/rm -rf "$HOME/Library/Application Support/RelayDock"
while /usr/bin/security delete-generic-password -s app.relaydock.credentials >/dev/null 2>&1; do
    :
done

echo "RelayDock, its credentials, generated configuration, and local signing identity were removed."
