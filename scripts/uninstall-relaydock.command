#!/bin/zsh
set -euo pipefail
export LC_ALL=C
export LANG=C

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

BRIDGE_CERTIFICATE="$HOME/Library/Application Support/RelayDock/Bridge/api.anthropic.com.pem"
if ! DEFAULT_USER_KEYCHAIN_OUTPUT="$(/usr/bin/security default-keychain -d user 2>&1)"; then
    echo "Could not determine the default user Keychain. RelayDock was left in place."
    echo "$DEFAULT_USER_KEYCHAIN_OUTPUT"
    exit 1
fi
DEFAULT_USER_KEYCHAIN="$(print -r -- "$DEFAULT_USER_KEYCHAIN_OUTPUT" \
    | /usr/bin/sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//')"
if [[ "$DEFAULT_USER_KEYCHAIN" != /* ]]; then
    echo "The default user Keychain path is invalid. RelayDock was left in place."
    exit 1
fi
RECOVERY_DIRECTORY="$(/usr/bin/mktemp -d -t relaydock-bridge-certificates)"
cleanup_bridge_recovery() {
    if [[ "${RECOVERY_DIRECTORY:t}" == relaydock-bridge-certificates.* ]]; then
        /bin/rm -rf "$RECOVERY_DIRECTORY"
    fi
}
trap cleanup_bridge_recovery EXIT

split_bridge_certificates() {
    local source_file="$1"
    local prefix="$2"
    /usr/bin/awk -v dir="$RECOVERY_DIRECTORY" -v prefix="$prefix" '
        /-----BEGIN CERTIFICATE-----/ { count += 1; output = sprintf("%s/%s-%04d.pem", dir, prefix, count) }
        output != "" { print > output }
        /-----END CERTIFICATE-----/ { close(output); output = "" }
    ' "$source_file"
}

is_relaydock_bridge_certificate() {
    local certificate="$1"
    local details dns_names
    details="$(/usr/bin/openssl x509 -noout -text -in "$certificate" 2>/dev/null || true)"
    dns_names="$(print -r -- "$details" | /usr/bin/grep -o 'DNS:[^,[:space:]]*' | /usr/bin/sort -u || true)"
    [[ "$dns_names" == "DNS:api.anthropic.com" ]] \
        && [[ "$details" == *"CA:FALSE"* ]] \
        && [[ "$details" == *"TLS Web Server Authentication"* ]]
}

TRUST_CLEAN=0
for PASS in {1..8}; do
    /bin/rm -f "$RECOVERY_DIRECTORY"/candidate-*.pem(N)
    if [[ -f "$BRIDGE_CERTIFICATE" ]]; then
        /bin/cp "$BRIDGE_CERTIFICATE" "$RECOVERY_DIRECTORY/candidate-local.pem"
    fi
    if ! /usr/bin/security find-certificate -a -c "RelayDock Anthropic Bridge" -p \
        "$DEFAULT_USER_KEYCHAIN" \
        >"$RECOVERY_DIRECTORY/all.pem" 2>"$RECOVERY_DIRECTORY/find-error.txt"; then
        echo "Could not query the Keychain for Anthropic Bridge certificates. RelayDock and its recovery material were left in place."
        /bin/cat "$RECOVERY_DIRECTORY/find-error.txt"
        exit 1
    fi
    split_bridge_certificates "$RECOVERY_DIRECTORY/all.pem" candidate

    REMOVED_TRUST=0
    for CANDIDATE in "$RECOVERY_DIRECTORY"/candidate-*.pem(N); do
        is_relaydock_bridge_certificate "$CANDIDATE" || continue
        if REMOVE_TRUST_OUTPUT="$(/usr/bin/security remove-trusted-cert "$CANDIDATE" 2>&1)"; then
            REMOVED_TRUST=1
        elif [[ "$REMOVE_TRUST_OUTPUT" != *"specified item could not be found in the keychain"* ]]; then
            echo "Could not remove every Anthropic Bridge trust entry. RelayDock and its certificate files were left in place."
            [[ -n "$REMOVE_TRUST_OUTPUT" ]] && echo "$REMOVE_TRUST_OUTPUT"
            exit 1
        fi
    done
    if [[ "$REMOVED_TRUST" == "0" ]]; then
        TRUST_CLEAN=1
        break
    fi
done
if [[ "$TRUST_CLEAN" != "1" ]]; then
    echo "Anthropic Bridge trust cleanup did not converge. RelayDock and its certificate files were left in place."
    exit 1
fi
cleanup_bridge_recovery
trap - EXIT

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

echo "RelayDock, its credentials, generated configuration, Anthropic Bridge certificate/private key/trust, and local signing identity were removed."
