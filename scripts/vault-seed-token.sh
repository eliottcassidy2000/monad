#!/usr/bin/env bash
set -euo pipefail

# ── Seed a Claude Pro/Max token into Vault ───────────────────────────
#
# Usage (run on any cluster node with claude logged in):
#
#   ./scripts/vault-seed-token.sh account-a
#   ./scripts/vault-seed-token.sh account-b ~/.claude/.credentials.json
#
# That's it. Four commands (one per account) and you're done.
# ────────────────────────────────────────────────────────────────────

ACCOUNT="${1:?Usage: $0 <account-name> [credentials-path]}"
CREDS_PATH="${2:-${HOME}/.claude/.credentials.json}"

VAULT_ADDR="${VAULT_ADDR:-http://192.168.50.19:8200}"
KEYS_FILE="/opt/vault/data/.vault-keys.json"

# Auto-authenticate: read root token from local keys file
if [ -z "${VAULT_TOKEN:-}" ]; then
    if [ -f "$KEYS_FILE" ]; then
        VAULT_TOKEN=$(sudo python3 -c "import json; print(json.load(open('$KEYS_FILE'))['root_token'])" 2>/dev/null) || {
            # Try without sudo (if file is readable)
            VAULT_TOKEN=$(python3 -c "import json; print(json.load(open('$KEYS_FILE'))['root_token'])" 2>/dev/null) || {
                echo "Error: Cannot read $KEYS_FILE"
                echo "Run with sudo or export VAULT_TOKEN manually."
                exit 1
            }
        }
    else
        echo "Error: No VAULT_TOKEN set and no keys file at $KEYS_FILE"
        echo "If running from a remote node: export VAULT_TOKEN=<root-token>"
        exit 1
    fi
fi

if [ ! -f "$CREDS_PATH" ]; then
    echo "Error: $CREDS_PATH not found"
    echo ""
    echo "Log in first:  claude login"
    echo "Then re-run:   $0 $ACCOUNT"
    exit 1
fi

# Validate JSON
python3 -c "import json; json.load(open('$CREDS_PATH'))" 2>/dev/null || {
    echo "Error: $CREDS_PATH is not valid JSON"
    exit 1
}

# Grab auth metadata if claude CLI is available
EMAIL="unknown"
SUB_TYPE="unknown"
if command -v claude &>/dev/null; then
    AUTH_META=$(claude auth status 2>/dev/null || echo '{}')
    EMAIL=$(echo "$AUTH_META" | python3 -c "import sys,json; print(json.load(sys.stdin).get('email','unknown'))" 2>/dev/null || echo "unknown")
    SUB_TYPE=$(echo "$AUTH_META" | python3 -c "import sys,json; print(json.load(sys.stdin).get('subscriptionType','unknown'))" 2>/dev/null || echo "unknown")
fi

# Build the JSON payload
CREDS_JSON=$(cat "$CREDS_PATH")
PAYLOAD=$(python3 -c "
import json, sys
creds = json.load(open('$CREDS_PATH'))
payload = {
    'data': {
        'credentials_json': json.dumps(creds),
        'email': '$EMAIL',
        'subscription': '$SUB_TYPE',
        'seeded_at': '$(date -Iseconds)',
        'seeded_from': '$(hostname)'
    }
}
print(json.dumps(payload))
")

# Write to Vault via HTTP API
RESP=$(curl -sf -X PUT "$VAULT_ADDR/v1/secret/data/claude-tokens/${ACCOUNT}" \
    -H "X-Vault-Token: $VAULT_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD") || {
    echo "Error: Failed to write to Vault at $VAULT_ADDR"
    echo "Check that Vault is running and unsealed."
    exit 1
}

VERSION=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['version'])" 2>/dev/null || echo "?")

echo ""
echo "Stored '${ACCOUNT}' in Vault (version $VERSION)."
echo "  email:        $EMAIL"
echo "  subscription: $SUB_TYPE"
echo "  source:       $(hostname):$CREDS_PATH"
