#!/bin/zsh
set -euo pipefail

EXISTING_KIND="${1:?existing kind required}"
EXISTING_IDENTITY="${2:-}"
INCOMING_KIND="${3:?incoming kind required}"
INCOMING_IDENTITY="${4:-}"
REPAIR_ALLOWED="${5:-0}"
DEVELOPER_ADOPTION_ALLOWED="${6:-0}"

case "$EXISTING_KIND" in
    none|adhoc)
        exit 0
        ;;
    local)
        if [[ "$INCOMING_KIND" == "developer" && -n "$INCOMING_IDENTITY" \
              && "$DEVELOPER_ADOPTION_ALLOWED" == "1" ]]; then
            # The installer separately records explicit adoption of this exact
            # TeamIdentifier and bundle signing identifier.
            exit 0
        fi
        if [[ "$INCOMING_KIND" == "local" && -n "$EXISTING_IDENTITY" \
              && ( "$EXISTING_IDENTITY" == "$INCOMING_IDENTITY" || "$REPAIR_ALLOWED" == "1" ) ]]; then
            exit 0
        fi
        ;;
    developer)
        if [[ "$INCOMING_KIND" == "developer" && -n "$EXISTING_IDENTITY" \
              && "$EXISTING_IDENTITY" == "$INCOMING_IDENTITY" ]]; then
            exit 0
        fi
        ;;
esac

echo "Signing identity transition rejected: $EXISTING_KIND -> $INCOMING_KIND" >&2
exit 4
