#!/usr/bin/env bash
# join.sh — self-organizing cluster join
#
# Usage:
#   curl -sL https://raw.githubusercontent.com/claude-monad/monad/main/meta/bootstrap/join.sh \
#     | bash -s -- [claude-account]
#
#   [claude-account]  optional tag for job scheduling (default: "max")
#
# What it does:
#   1. Ensures Tailscale is up
#   2. Scans the tailnet for existing Nomad servers
#   3. If a cluster exists → joins it (as server or client, auto-decided)
#   4. If no cluster exists → bootstraps a new single-server cluster
#   5. Installs toolchains, node-doctor cron, verifies health
#
# Idempotent: safe to re-run.
set -euo pipefail

CLAUDE_ACCOUNT="${1:-max}"
REPO_URL="https://github.com/claude-monad/monad.git"
NOMAD_PORT=4646
NOMAD_RPC_PORT=4647
NOMAD_SERF_PORT=4648

log()  { printf '\033[0;36m[join]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[join]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[0;31m[join]\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# ── Detect OS ────────────────────────────────────────────────────────────────
OS="unknown"
case "$(uname -s)" in
  Linux*)  OS="linux" ;;
  Darwin*) OS="macos" ;;
  MINGW*|MSYS*|CYGWIN*) OS="windows" ;;
esac
[ "$OS" = "windows" ] && die "Windows not supported by this script. See JOIN.md."
log "OS: $OS | account: $CLAUDE_ACCOUNT"

SUDO=""
[ "$(id -u)" -ne 0 ] && have sudo && SUDO="sudo"
NODE_NAME="$(hostname)"

# ── 1. Tailscale ─────────────────────────────────────────────────────────────
if have tailscale && tailscale status >/dev/null 2>&1; then
  log "tailscale already up"
else
  log "installing tailscale…"
  if [ "$OS" = "linux" ]; then
    have tailscale || curl -fsSL https://tailscale.com/install.sh | $SUDO sh
    $SUDO tailscale up || die "run 'sudo tailscale up', authenticate in browser, then re-run join.sh"
  else
    die "install Tailscale from https://tailscale.com/download/mac, sign in, then re-run."
  fi
fi

MY_IP="$(tailscale ip -4 2>/dev/null | head -1)"
[ -z "$MY_IP" ] && die "no Tailscale IPv4 — run 'sudo tailscale up' and authenticate first."
log "this node: $NODE_NAME ($MY_IP)"

# ── 2. Clone monad repo ─────────────────────────────────────────────────────
DEST="${MONAD_REPO_DIR:-$HOME/monad}"
if [ -d "$DEST/.git" ]; then
  log "monad repo at $DEST — pulling…"
  git -C "$DEST" pull --ff-only 2>/dev/null || warn "could not fast-forward $DEST"
else
  log "cloning monad → $DEST"
  git clone "$REPO_URL" "$DEST"
fi

# ── 3. Install toolchains ───────────────────────────────────────────────────
TOOLCHAIN_SCRIPT="$DEST/meta/bootstrap/install-toolchains.sh"
if [ -f "$TOOLCHAIN_SCRIPT" ]; then
  log "installing toolchains…"
  bash "$TOOLCHAIN_SCRIPT" || warn "some toolchains failed — see above"
else
  log "no install-toolchains.sh found — skipping (install Nomad/Docker/Claude manually if needed)"
fi

# ── 4. Ensure Nomad is installed ─────────────────────────────────────────────
if ! have nomad; then
  log "installing Nomad…"
  if [ "$OS" = "linux" ]; then
    curl -fsSL https://apt.releases.hashicorp.com/gpg | $SUDO gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg 2>/dev/null
    echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
      | $SUDO tee /etc/apt/sources.list.d/hashicorp.list > /dev/null
    $SUDO apt-get update -qq && $SUDO apt-get install -y -qq nomad
  else
    die "install Nomad manually: https://developer.hashicorp.com/nomad/install"
  fi
fi
log "nomad: $(nomad version | head -1)"

# ── 5. Discover existing cluster on the tailnet ─────────────────────────────
# Scan all online Tailscale peers for a Nomad server on port 4646.
log "scanning tailnet for existing Nomad cluster…"

DISCOVERED_SERVERS=()
DISCOVERED_IPS=()

# Get all peer IPs from tailscale status (online peers only)
PEER_IPS=()
while IFS= read -r line; do
  # tailscale status format: IP  hostname  user  os  status...
  ip=$(echo "$line" | awk '{print $1}')
  status_field=$(echo "$line" | awk '{for(i=4;i<=NF;i++) printf "%s ", $i}')
  # Skip offline peers and ourselves
  if echo "$status_field" | grep -qi "offline"; then
    continue
  fi
  if [ "$ip" = "$MY_IP" ]; then
    continue
  fi
  # Only consider valid Tailscale IPs (100.x.x.x)
  if echo "$ip" | grep -qE '^100\.'; then
    PEER_IPS+=("$ip")
  fi
done < <(tailscale status 2>/dev/null | grep -v '^#' | grep -v '^$')

log "found ${#PEER_IPS[@]} online tailnet peers"

for ip in "${PEER_IPS[@]}"; do
  # Quick probe: can we reach Nomad HTTP API?
  if curl -s --connect-timeout 2 "http://${ip}:${NOMAD_PORT}/v1/status/leader" >/dev/null 2>&1; then
    log "  found Nomad at $ip"
    # Check if it's a server (has server members)
    members=$(curl -s --connect-timeout 2 "http://${ip}:${NOMAD_PORT}/v1/status/peers" 2>/dev/null || echo "[]")
    if [ "$members" != "[]" ] && [ -n "$members" ]; then
      DISCOVERED_SERVERS+=("$ip")
    fi
    DISCOVERED_IPS+=("$ip")
  fi
done

# Also check if WE are already running a Nomad server
if curl -s --connect-timeout 2 "http://${MY_IP}:${NOMAD_PORT}/v1/status/leader" >/dev/null 2>&1; then
  log "  this node already running Nomad"
  ALREADY_RUNNING=true
else
  ALREADY_RUNNING=false
fi

# ── 6. Decide role: bootstrap new cluster vs join existing ───────────────────

# Count total nodes that will be in the cluster
TOTAL_NODES=$(( ${#DISCOVERED_IPS[@]} + 1 ))  # peers + us

# Desired server count based on cluster size
desired_servers() {
  local n=$1
  if [ "$n" -le 2 ]; then
    echo 1
  elif [ "$n" -le 6 ]; then
    echo 3
  else
    echo 5
  fi
}

DESIRED_SERVERS=$(desired_servers "$TOTAL_NODES")
CURRENT_SERVERS=${#DISCOVERED_SERVERS[@]}

if [ ${#DISCOVERED_SERVERS[@]} -eq 0 ]; then
  # No existing cluster found — bootstrap as the first server
  ROLE="bootstrap"
  log "no existing cluster found — bootstrapping new cluster as server+client"
else
  # Existing cluster found — should we be a server or just a client?
  if [ "$CURRENT_SERVERS" -lt "$DESIRED_SERVERS" ]; then
    ROLE="server-join"
    log "cluster has $CURRENT_SERVERS servers, needs $DESIRED_SERVERS — joining as server+client"
  else
    ROLE="client"
    log "cluster has $CURRENT_SERVERS servers (sufficient) — joining as client"
  fi
fi

# Pick a server to join (use the first discovered, which is the leader or reachable)
JOIN_SERVER="${DISCOVERED_SERVERS[0]:-}"

# ── 7. Write Nomad config ───────────────────────────────────────────────────
$SUDO mkdir -p /opt/nomad/data /etc/nomad.d

# If we're bootstrapping fresh or changing roles, clear stale data
if [ "$ALREADY_RUNNING" = "false" ]; then
  $SUDO rm -rf /opt/nomad/data/*
fi

write_config() {
  local config_role="$1"  # bootstrap | server-join | client

  local server_block=""
  local client_servers=""

  case "$config_role" in
    bootstrap)
      server_block='server {
  enabled          = true
  bootstrap_expect = 1
}'
      ;;
    server-join)
      server_block="server {
  enabled          = true
  bootstrap_expect = $DESIRED_SERVERS
  server_join {
    retry_join = [\"${JOIN_SERVER}:${NOMAD_SERF_PORT}\"]
  }
}"
      ;;
    client)
      client_servers="  servers = [\"${JOIN_SERVER}:${NOMAD_RPC_PORT}\"]"
      ;;
  esac

  cat <<EOF
# Monad Cluster — auto-generated by join.sh
# Role: $config_role | Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')

log_level = "INFO"
data_dir  = "/opt/nomad/data"
name      = "$NODE_NAME"

bind_addr = "$MY_IP"

advertise {
  http = "$MY_IP"
  rpc  = "$MY_IP"
  serf = "$MY_IP"
}

ports {
  http = $NOMAD_PORT
  rpc  = $NOMAD_RPC_PORT
  serf = $NOMAD_SERF_PORT
}

$server_block

client {
  enabled = true
$client_servers

  meta {
    role           = "$config_role"
    has_claude     = "true"
    claude_account = "$CLAUDE_ACCOUNT"
  }
}

plugin "docker" {
  config {
    allow_privileged = false
    volumes {
      enabled = true
    }
  }
}

plugin "raw_exec" {
  config {
    enabled = true
  }
}

telemetry {
  disable_hostname           = true
  prometheus_metrics         = true
  publish_allocation_metrics = true
  publish_node_metrics       = true
}
EOF
}

CONFIG_CONTENT="$(write_config "$ROLE")"
echo "$CONFIG_CONTENT" | $SUDO tee /etc/nomad.d/nomad.hcl > /dev/null
log "wrote Nomad config (role: $ROLE)"

# ── 8. Start/restart Nomad ──────────────────────────────────────────────────
$SUDO systemctl enable nomad 2>/dev/null || true
$SUDO systemctl restart nomad
log "nomad restarted — waiting for bootstrap…"
sleep 5

export NOMAD_ADDR="http://${MY_IP}:${NOMAD_PORT}"

# Verify
if nomad node status -self >/dev/null 2>&1; then
  log "node is running and connected"
  nomad server members 2>/dev/null && true
  echo ""
  nomad node status 2>/dev/null && true
else
  warn "node started but not yet connected — may need a moment"
  warn "check: NOMAD_ADDR=$NOMAD_ADDR nomad node status"
fi

# ── 9. Claude login check ───────────────────────────────────────────────────
if have claude; then
  if [ -f "$HOME/.claude/.credentials.json" ]; then
    log "claude CLI present and logged in"
  else
    warn "ACTION NEEDED: run 'claude' and log in with your account"
  fi
else
  warn "claude CLI not installed — install it, then run 'claude' to log in"
fi

# ── 10. Node-doctor cron ────────────────────────────────────────────────────
if have crontab; then
  if crontab -l 2>/dev/null | grep -q 'node-doctor.sh'; then
    log "node-doctor cron already installed"
  else
    ( crontab -l 2>/dev/null; echo "0 */8 * * * $DEST/scripts/node-doctor.sh >> /tmp/node-doctor.log 2>&1" ) | crontab -
    log "installed node-doctor cron (every 8h)"
  fi
fi

# ── Done ─────────────────────────────────────────────────────────────────────
log "════════════════════════════════════════════════════════════════"
log "join complete!"
log ""
log "  node:    $NODE_NAME ($MY_IP)"
log "  role:    $ROLE"
log "  account: $CLAUDE_ACCOUNT"
log "  verify:  NOMAD_ADDR=$NOMAD_ADDR nomad node status"
log ""
log "other machines can join this cluster by running:"
log "  curl -sL https://raw.githubusercontent.com/claude-monad/monad/main/meta/bootstrap/join.sh | bash"
log "════════════════════════════════════════════════════════════════"
