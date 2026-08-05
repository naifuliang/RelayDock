#!/bin/zsh
set -euo pipefail

APP_PATH="${1:?Usage: local-sign-relaydock.sh /path/to/RelayDock.app}"
IDENTITY="RelayDock Local Signing"
SIGNING_ROOT="${RELAYDOCK_SIGNING_ROOT:-$HOME/Library/Application Support/RelayDock/Signing}"
KEYCHAIN_PATH="${RELAYDOCK_SIGNING_KEYCHAIN_PATH:-$HOME/Library/Keychains/RelayDockLocalSigning.keychain-db}"
PASSWORD_PATH="$SIGNING_ROOT/keychain-password"

if [[ ! -d "$APP_PATH" ]]; then
    echo "RelayDock.app was not found at $APP_PATH"
    exit 1
fi

/bin/mkdir -p "$SIGNING_ROOT"
/bin/chmod 700 "$SIGNING_ROOT"
umask 077

if [[ ! -f "$KEYCHAIN_PATH" || ! -f "$PASSWORD_PATH" ]]; then
    TEMP_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/relaydock-signing.XXXXXX")"
    cleanup_signing() { /bin/rm -rf "$TEMP_DIR"; }
    trap cleanup_signing EXIT

    /usr/bin/security delete-keychain "$KEYCHAIN_PATH" >/dev/null 2>&1 || /bin/rm -f "$KEYCHAIN_PATH"
    PASSWORD="$(/usr/bin/openssl rand -hex 24)"
    /usr/bin/printf '%s' "$PASSWORD" > "$PASSWORD_PATH"
    /bin/chmod 600 "$PASSWORD_PATH"

    /usr/bin/printf '%s\n' \
        '[req]' \
        'distinguished_name = dn' \
        'x509_extensions = extensions' \
        'prompt = no' \
        '[dn]' \
        'CN = RelayDock Local Signing' \
        'O = RelayDock Local' \
        '[extensions]' \
        'basicConstraints = critical,CA:false' \
        'keyUsage = critical,digitalSignature' \
        'extendedKeyUsage = codeSigning' \
        'subjectKeyIdentifier = hash' > "$TEMP_DIR/openssl.cnf"

    /usr/bin/openssl req -new -newkey rsa:2048 -nodes -x509 -days 3650 \
        -config "$TEMP_DIR/openssl.cnf" \
        -keyout "$TEMP_DIR/signing.key" \
        -out "$TEMP_DIR/signing.crt"
    /usr/bin/openssl pkcs12 -export \
        -inkey "$TEMP_DIR/signing.key" \
        -in "$TEMP_DIR/signing.crt" \
        -name "$IDENTITY" \
        -passout "pass:$PASSWORD" \
        -out "$TEMP_DIR/signing.p12"

    /usr/bin/security create-keychain -p "$PASSWORD" "$KEYCHAIN_PATH"
    /usr/bin/security unlock-keychain -p "$PASSWORD" "$KEYCHAIN_PATH"
    /usr/bin/security import "$TEMP_DIR/signing.p12" \
        -k "$KEYCHAIN_PATH" -P "$PASSWORD" -T /usr/bin/codesign >/dev/null
    /usr/bin/security set-key-partition-list \
        -S apple-tool:,apple:,codesign: -s -k "$PASSWORD" "$KEYCHAIN_PATH" >/dev/null
    /bin/chmod 600 "$KEYCHAIN_PATH"
else
    PASSWORD="$(<"$PASSWORD_PATH")"
    /usr/bin/security unlock-keychain -p "$PASSWORD" "$KEYCHAIN_PATH"
fi

/usr/bin/codesign --force --deep --options runtime \
    --keychain "$KEYCHAIN_PATH" --sign "$IDENTITY" "$APP_PATH"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "RelayDock was signed with its stable local signing identity."
