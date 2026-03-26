#!/usr/bin/env bash
# Bootstrap a new node into the Monad cluster
# Usage: curl -sL <raw-url> | sudo bash -s -- [server|client] <server_ip>
#
# Safe to re-run — idempotent (won't reinstall or overwrite working config)
set -euo pipefail

ROLE="${1:-client}"
SERVER_IP="${2:-100.78.218.70}"
NODE_NAME="$(hostname)"
MONAD_DIR="${MONAD_DIR:-/home/${SUDO_USER:-$(whoami)}/monad}"

ok()  { echo -e "  ✓ $*"; }
err() { echo -e "  ✗ $*" >&2; }
step() { echo -e "\n==> $*"; }

# ─── Pre-flight checks ───────────────────────────────────────────────────────

step "Pre-flight checks"

# Must be root
if [ "$(id -u)" -ne 0 ]; then
    err "This script must be run as root (use sudo)"
    exit 1
fi

# Tailscale must be installed and running
if ! command -v tailscale &>/dev/null; then
    err "Tailscale is not installed. Install it first: https://tailscale.com/download"
    exit 1
fi

TAILSCALE_IP="$(tailscale ip -4 2>/dev/null || true)"
if [ -z "$TAILSCALE_IP" ]; then
    err "Tailscale is installed but has no IPv4 address. Run: tailscale up"
    exit 1
fi
ok "Tailscale: $TAILSCALE_IP"

# Can we reach the server?
if curl -s --connect-timeout 5 "http://${SERVER_IP}:4646/v1/status/leader" &>/dev/null; then
    ok "Nomad server reachable at $SERVER_IP"
else
    echo "  ⚠ Cannot reach Nomad server at $SERVER_IP:4646 (may be normal during initial setup)"
fi

echo ""
echo "  Node:   $NODE_NAME ($TAILSCALE_IP)"
echo "  Role:   $ROLE"
echo "  Server: $SERVER_IP"
echo "  Repo:   $MONAD_DIR"

# ─── Install Nomad ────────────────────────────────────────────────────────────

step "Nomad"
if command -v nomad &>/dev/null; then
    ok "Already installed: $(nomad version | head -1)"
else
    echo "  Installing..."
    curl -fsSL https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg 2>/dev/null
    echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
        > /etc/apt/sources.list.d/hashicorp.list
    apt-get update -qq && apt-get install -y -qq nomad
    ok "Installed: $(nomad version | head -1)"
fi

# ─── Install Docker ───────────────────────────────────────────────────────────

step "Docker"
if command -v docker &>/dev/null; then
    ok "Already installed: $(docker --version)"
else
    echo "  Installing..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -qq && apt-get install -y -qq docker-ce docker-ce-cli containerd.io
    ok "Installed: $(docker --version)"
fi

# ─── Clone monad repo ─────────────────────────────────────────────────────────

step "Monad repository"
if [ -d "$MONAD_DIR/.git" ]; then
    ok "Already cloned at $MONAD_DIR"
    cd "$MONAD_DIR" && git pull --quiet origin main 2>/dev/null || true
else
    mkdir -p "$(dirname "$MONAD_DIR")"
    git clone https://github.com/claude-monad/monad.git "$MONAD_DIR"
    ok "Cloned to $MONAD_DIR"
fi

# ─── Write Nomad config ──────────────────────────────────────────────────────

step "Nomad configuration"
mkdir -p /opt/nomad/data /etc/nomad.d

TEMPLATE="$MONAD_DIR/cluster/${ROLE}.hcl"
if [ ! -f "$TEMPLATE" ]; then
    err "Template not found: $TEMPLATE"
    exit 1
fi

# Only overwrite config if it doesn't exist or template is newer
TARGET="/etc/nomad.d/nomad.hcl"
if [ -f "$TARGET" ] && [ "$TARGET" -nt "$TEMPLATE" ]; then
    ok "Config already exists and is newer than template (keeping)"
else
    sed -e "s/TAILSCALE_IP/$TAILSCALE_IP/g" \
        -e "s/NODE_NAME/$NODE_NAME/g" \
        -e "s/SERVER_IP/$SERVER_IP/g" \
        "$TEMPLATE" > "$TARGET"
    ok "Config written from $ROLE template"
fi

# ─── Start Nomad ──────────────────────────────────────────────────────────────

step "Starting Nomad"
systemctl enable nomad 2>/dev/null || true
systemctl restart nomad

echo "  Waiting for agent to start..."
sleep 5

export NOMAD_ADDR="http://$TAILSCALE_IP:4646"
if nomad node status -self &>/dev/null; then
    ok "Node is running and connected"
    nomad node status -self | head -10
else
    echo "  ⚠ Agent started but not yet connected. This may take a moment."
    echo "    Check: NOMAD_ADDR=$NOMAD_ADDR nomad node status"
fi

# ─── Post-setup reminders ────────────────────────────────────────────────────

step "Next steps"
echo "  1. Install Claude Code CLI: https://docs.anthropic.com/en/docs/claude-code"
echo "  2. Log in to Claude with the assigned account: claude"
echo "  3. Set claude_account meta in /etc/nomad.d/nomad.hcl:"
echo "       meta { claude_account = \"max-1\" }  # or max-2, max-3, pro"
echo "  4. Set up node-doctor cron:"
echo "       crontab -e"
echo "       0 */8 * * * $MONAD_DIR/scripts/node-doctor.sh >> /var/log/node-doctor.log 2>&1"
echo "  5. Verify: NOMAD_ADDR=$NOMAD_ADDR nomad node status"
echo ""
ok "Setup complete for $NODE_NAME"
