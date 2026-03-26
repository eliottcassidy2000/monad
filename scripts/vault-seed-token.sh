#!/usr/bin/env bash
set -euo pipefail

# ── Seed a Claude Pro/Max token into Vault ───────────────────────────
#
# Usage (run on any machine with claude logged in):
#
#   ./scripts/vault-seed-token.sh account-a
#   ./scripts/vault-seed-token.sh account-b ~/.claude/.credentials.json
#
# That's it. Vault handles the rest.
# ────────────────────────────────────────────────────────────────────

ACCOUNT="${1:?Usage: $0 <account-name> [credentials-path]}"
CREDS_PATH="${2:-${HOME}/.claude/.credentials.json}"

VAULT_ADDR="${VAULT_ADDR:-http://100.78.218.70:8200}"
export VAULT_ADDR

# Auto-authenticate: read root token from vault-data on server
KEYS_FILE="/opt/vault/data/.vault-keys.json"
if [ -z "${VAULT_TOKEN:-}" ]; then
    if [ -f "$KEYS_FILE" ]; then
        export VAULT_TOKEN=$(sed -n 's/.*"root_token":"\([^"]*\)".*/\1/p' "$KEYS_FILE")
    else
        echo "Error: No VAULT_TOKEN set and no keys file at $KEYS_FILE"
        echo "If running remotely, export VAULT_TOKEN=<root-token> first."
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

# Also grab auth status metadata if available
AUTH_META=""
if command -v claude &>/dev/null; then
    AUTH_META=$(claude auth status 2>/dev/null || echo '{}')
fi

EMAIL=$(echo "$AUTH_META" | python3 -c "import sys,json; print(json.load(sys.stdin).get('email','unknown'))" 2>/dev/null || echo "unknown")
SUB_TYPE=$(echo "$AUTH_META" | python3 -c "import sys,json; print(json.load(sys.stdin).get('subscriptionType','unknown'))" 2>/dev/null || echo "unknown")

CREDS_JSON=$(cat "$CREDS_PATH")

vault kv put "secret/claude-tokens/${ACCOUNT}" \
    credentials_json="$CREDS_JSON" \
    email="$EMAIL" \
    subscription="$SUB_TYPE" \
    seeded_at="$(date -Iseconds)" \
    seeded_from="$(hostname)"

echo ""
echo "Stored '${ACCOUNT}' in Vault."
echo "  email:        $EMAIL"
echo "  subscription: $SUB_TYPE"
echo "  source:       $(hostname):$CREDS_PATH"
echo ""
echo "Verify:  VAULT_ADDR=$VAULT_ADDR vault kv get secret/claude-tokens/${ACCOUNT}"
