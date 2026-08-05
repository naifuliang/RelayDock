#!/bin/zsh
set -euo pipefail

APP_PATH="/Applications/RelayDock.app"
USER_APP_PATH="$HOME/Applications/RelayDock.app"

echo "RelayDock Uninstaller"
echo "This removes RelayDock, its preferences, and its saved gateway API key."
read "REPLY?Continue? [y/N] "

if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
fi

pkill -x RelayDock 2>/dev/null || true

if [[ -e "$APP_PATH" ]]; then
    sudo rm -rf "$APP_PATH"
fi

if [[ -e "$USER_APP_PATH" ]]; then
    rm -rf "$USER_APP_PATH"
fi

defaults delete app.relaydock.mac 2>/dev/null || true
security delete-generic-password \
    -s app.relaydock.credentials \
    -a gateway-api-key 2>/dev/null || true

echo "RelayDock was removed. No system proxy or certificate was installed by this version."
