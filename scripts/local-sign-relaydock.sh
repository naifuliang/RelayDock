#!/bin/zsh
set -euo pipefail

APP_PATH="${1:?Usage: local-sign-relaydock.sh /path/to/RelayDock.app}"
IDENTITY="RelayDock Local Signing"
SIGNING_ROOT="${RELAYDOCK_SIGNING_ROOT:-$HOME/Library/Application Support/RelayDock/Signing}"
KEYCHAIN_PATH="${RELAYDOCK_SIGNING_KEYCHAIN_PATH:-$HOME/Library/Keychains/RelayDockLocalSigning.keychain-db}"
PASSWORD_PATH="$SIGNING_ROOT/keychain-password"
REQUIREMENT_PATH="$SIGNING_ROOT/designated-requirement"
REPAIR_IDENTITY="${RELAYDOCK_REPAIR_SIGNING_IDENTITY:-0}"
TEMP_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/relaydock-signing.XXXXXX")"

cleanup_signing() { /bin/rm -rf "$TEMP_DIR"; }
trap cleanup_signing EXIT

if [[ ! -d "$APP_PATH" ]]; then
    echo "RelayDock.app was not found at $APP_PATH"
    exit 1
fi

/bin/mkdir -p "$SIGNING_ROOT"
/bin/chmod 700 "$SIGNING_ROOT"
umask 077

archive_damaged_identity() {
    local recovery_root="$SIGNING_ROOT/Recovery"
    local recovery_dir
    /bin/mkdir -p "$recovery_root"
    recovery_dir="$(/usr/bin/mktemp -d "$recovery_root/identity.XXXXXX")"
    /bin/chmod 700 "$recovery_root" "$recovery_dir"
    [[ -f "$KEYCHAIN_PATH" ]] && /bin/mv "$KEYCHAIN_PATH" "$recovery_dir/RelayDockLocalSigning.keychain-db"
    [[ -f "$PASSWORD_PATH" ]] && /bin/mv "$PASSWORD_PATH" "$recovery_dir/keychain-password"
    [[ -f "$REQUIREMENT_PATH" ]] && /bin/mv "$REQUIREMENT_PATH" "$recovery_dir/designated-requirement"
    echo "The damaged signing identity was preserved in:"
    echo "  $recovery_dir"
}

create_identity() {
    local password
    password="$(/usr/bin/openssl rand -hex 24)"
    /usr/bin/printf '%s' "$password" > "$PASSWORD_PATH"
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
        -passout "pass:$password" \
        -out "$TEMP_DIR/signing.p12"

    /usr/bin/security create-keychain -p "$password" "$KEYCHAIN_PATH"
    /usr/bin/security unlock-keychain -p "$password" "$KEYCHAIN_PATH"
    /usr/bin/security import "$TEMP_DIR/signing.p12" \
        -k "$KEYCHAIN_PATH" -P "$password" -T /usr/bin/codesign >/dev/null
    /usr/bin/security set-key-partition-list \
        -S apple-tool:,apple:,codesign: -s -k "$password" "$KEYCHAIN_PATH" >/dev/null
    /bin/chmod 600 "$KEYCHAIN_PATH"
}

KEYCHAIN_EXISTS=0
PASSWORD_EXISTS=0
[[ -f "$KEYCHAIN_PATH" ]] && KEYCHAIN_EXISTS=1
[[ -f "$PASSWORD_PATH" ]] && PASSWORD_EXISTS=1

if [[ "$KEYCHAIN_EXISTS" != "$PASSWORD_EXISTS" ]]; then
    if [[ "$REPAIR_IDENTITY" == "1" ]]; then
        archive_damaged_identity
        KEYCHAIN_EXISTS=0
        PASSWORD_EXISTS=0
    else
        echo "RelayDock's local signing identity is incomplete; installation stopped."
        echo "The existing identity was not replaced because that could invalidate"
        echo "access to saved endpoint API keys. Run the installer again and choose"
        echo "the explicit signing-identity repair option."
        exit 4
    fi
fi

if [[ "$KEYCHAIN_EXISTS" == "0" ]]; then
    create_identity
fi

PASSWORD="$(<"$PASSWORD_PATH")"
if ! /usr/bin/security unlock-keychain -p "$PASSWORD" "$KEYCHAIN_PATH"; then
    if [[ "$REPAIR_IDENTITY" == "1" ]]; then
        archive_damaged_identity
        create_identity
        PASSWORD="$(<"$PASSWORD_PATH")"
        /usr/bin/security unlock-keychain -p "$PASSWORD" "$KEYCHAIN_PATH"
    else
        echo "RelayDock's local signing keychain could not be unlocked."
        echo "It was left untouched. Run the installer again and choose the explicit"
        echo "signing-identity repair option."
        exit 4
    fi
fi

# Prove that both the certificate and its private key are usable. Merely
# checking that two files exist allowed a partially damaged setup to rotate or
# strand the Keychain ACL in earlier releases.
/usr/bin/ditto "$APP_PATH/Contents/MacOS/RelayDock" "$TEMP_DIR/signing-probe"
if ! /usr/bin/codesign --force --options runtime --keychain "$KEYCHAIN_PATH" \
    --sign "$IDENTITY" "$TEMP_DIR/signing-probe"; then
    if [[ "$REPAIR_IDENTITY" == "1" ]]; then
        archive_damaged_identity
        create_identity
        PASSWORD="$(<"$PASSWORD_PATH")"
        /usr/bin/security unlock-keychain -p "$PASSWORD" "$KEYCHAIN_PATH"
        /usr/bin/codesign --force --options runtime --keychain "$KEYCHAIN_PATH" \
            --sign "$IDENTITY" "$TEMP_DIR/signing-probe"
    else
        echo "RelayDock's local signing certificate/private key is unusable."
        echo "The existing material was left untouched. Run the installer again and"
        echo "choose the explicit signing-identity repair option."
        exit 4
    fi
fi
CURRENT_REQUIREMENT="$(/usr/bin/codesign -d -r- "$TEMP_DIR/signing-probe" 2>&1 | /usr/bin/sed -n 's/^designated => //p')"
if [[ -z "$CURRENT_REQUIREMENT" || "$CURRENT_REQUIREMENT" != *'certificate root = H"'* ]]; then
    echo "RelayDock could not derive a certificate-bound signing requirement."
    exit 4
fi

if [[ -f "$REQUIREMENT_PATH" ]]; then
    SAVED_REQUIREMENT="$(<"$REQUIREMENT_PATH")"
    if [[ "$SAVED_REQUIREMENT" != "$CURRENT_REQUIREMENT" ]]; then
        echo "RelayDock's signing certificate fingerprint changed unexpectedly."
        echo "Installation stopped before the application was modified."
        exit 4
    fi
else
    /usr/bin/printf '%s' "$CURRENT_REQUIREMENT" > "$REQUIREMENT_PATH"
    /bin/chmod 600 "$REQUIREMENT_PATH"
fi

# v0.4-v0.5 added this private signing keychain to the user's general search
# list. A damaged custom keychain can then poison unrelated login-keychain
# queries. codesign already receives --keychain explicitly, so remove only the
# exact RelayDock path and preserve every unrelated search-list entry.
USER_KEYCHAINS=("${(@f)$(/usr/bin/security list-keychains -d user | /usr/bin/sed -e 's/^[[:space:]]*"//' -e 's/"$//')}")
FILTERED_KEYCHAINS=()
REMOVED_SEARCH_ENTRY=0
for USER_KEYCHAIN in "${USER_KEYCHAINS[@]}"; do
    [[ -z "$USER_KEYCHAIN" ]] && continue
    if [[ "$USER_KEYCHAIN" == "$KEYCHAIN_PATH" ]]; then
        REMOVED_SEARCH_ENTRY=1
    else
        FILTERED_KEYCHAINS+=("$USER_KEYCHAIN")
    fi
done
if [[ "$REMOVED_SEARCH_ENTRY" == "1" ]]; then
    if (( ${#FILTERED_KEYCHAINS[@]} == 0 )); then
        FILTERED_KEYCHAINS+=("$HOME/Library/Keychains/login.keychain-db")
    fi
    if ! /usr/bin/security list-keychains -d user -s "${FILTERED_KEYCHAINS[@]}"; then
        echo "RelayDock could not remove its signing keychain from the general search list."
        echo "Installation stopped before the application was modified."
        exit 4
    fi
fi

/usr/bin/codesign --force --deep --options runtime \
    --keychain "$KEYCHAIN_PATH" --sign "$IDENTITY" "$APP_PATH"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "RelayDock was signed with its stable local signing identity."
echo "RELAYDOCK_DESIGNATED_REQUIREMENT=$CURRENT_REQUIREMENT"
