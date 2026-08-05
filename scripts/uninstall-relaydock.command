#!/bin/zsh
set -euo pipefail

APP_PATH="/Applications/RelayDock.app"
USER_APP_PATH="$HOME/Applications/RelayDock.app"

echo "RelayDock Uninstaller"
echo "This removes RelayDock, its preferences, generated OpenCode files, and saved gateway API keys."
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
/bin/rm -rf "$HOME/Library/Application Support/RelayDock"
while /usr/bin/security delete-generic-password -s app.relaydock.credentials >/dev/null 2>&1; do
    :
done

echo "RelayDock and its generated OpenCode configuration were removed."
