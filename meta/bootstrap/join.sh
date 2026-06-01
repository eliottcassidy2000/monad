#!/usr/bin/env bash
# join.sh — turn a fresh computer into a monad cluster node in one command.
#
# Usage:
#   curl -sL https://raw.githubusercontent.com/claude-monad/monad/main/meta/bootstrap/join.sh \
#     | bash -s -- <server-tailscale-ip> <claude-account> [role]
#
#   <server-tailscale-ip>  Nomad server to join (default: 100.87.219.108 = claudebox)
#   <claude-account>       which account this node is logged into: max-1|max-2|max-3|pro
#   [role]                 client (default) | server
#
# Idempotent: safe to re-run. Each step checks whether it is already done.
# What it does: Tailscale → Nomad client (via scripts/setup-node.sh) → toolchains →
# claude login → tag claude_account → node-doctor cron. Result: a full cluster member.
set -euo pipefail

SERVER_IP="${1:-100.87.219.108}"
CLAUDE_ACCOUNT="${2:-pro}"
ROLE="${3:-client}"
REPO_URL="https://github.com/claude-monad/monad.git"
RAW_BASE="https://raw.githubusercontent.com/claude-monad/monad/main"

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
log "detected OS: $OS  | server: $SERVER_IP  | account: $CLAUDE_ACCOUNT  | role: $ROLE"
[ "$OS" = "windows" ] && die "On Windows use meta/bootstrap/join.ps1 (or run setup-node manually — see root CLAUDE.md → Adding a New Node → Windows)."

SUDO=""
[ "$(id -u)" -ne 0 ] && have sudo && SUDO="sudo"

# ── 1. Tailscale (the cluster network) ───────────────────────────────────────
if have tailscale && tailscale status >/dev/null 2>&1; then
  log "tailscale already up: $(tailscale ip -4 2>/dev/null | head -1)"
else
  log "installing + starting tailscale…"
  if [ "$OS" = "linux" ]; then
    have tailscale || curl -fsSL https://tailscale.com/install.sh | $SUDO sh
    $SUDO tailscale up || warn "run 'sudo tailscale up' and authenticate in your browser, then re-run join.sh"
  else # macos
    have tailscale || die "install Tailscale from the App Store or https://tailscale.com/download/mac, sign in, then re-run."
    $SUDO tailscale up || warn "open Tailscale and sign in, then re-run join.sh"
  fi
fi
TS_IP="$(tailscale ip -4 2>/dev/null | head -1 || true)"
[ -n "$TS_IP" ] && log "this node's tailscale IP: $TS_IP" || warn "no tailscale IP yet — finish tailscale auth and re-run."

# ── 2. Clone the monad repo (so the node has the CLI + configs) ───────────────
DEST="${MONAD_REPO_DIR:-$HOME/monad}"
if [ -d "$DEST/.git" ]; then
  log "monad repo present at $DEST — pulling…"
  git -C "$DEST" pull --ff-only || warn "could not fast-forward $DEST"
else
  log "cloning monad → $DEST"
  git clone "$REPO_URL" "$DEST"
fi

# ── 3. Toolchains (Lean/elan, python, docker/podman, claude CLI) ──────────────
log "installing toolchains…"
bash "$DEST/meta/bootstrap/install-toolchains.sh" || warn "some toolchains failed — see output above"

# ── 4. Nomad client (reuses the existing, battle-tested node setup) ──────────
if have nomad && nomad node status >/dev/null 2>&1; then
  log "nomad already running and connected"
else
  log "joining Nomad cluster via scripts/setup-node.sh ($ROLE → $SERVER_IP)…"
  $SUDO bash "$DEST/scripts/setup-node.sh" "$ROLE" "$SERVER_IP" || warn "setup-node.sh reported an issue — check above"
fi

# ── 5. Tag this node's Claude account (so account-pinned jobs land here) ──────
# setup-node.sh writes the Nomad client config; we ensure meta.claude_account is set.
NOMAD_CFG="${NOMAD_CONFIG_DIR:-/etc/nomad.d}/client.hcl"
if [ -f "$NOMAD_CFG" ]; then
  if grep -q 'claude_account' "$NOMAD_CFG" 2>/dev/null; then
    log "claude_account already tagged in $NOMAD_CFG"
  else
    warn "add to $NOMAD_CFG inside the client{} block, then restart nomad:"
    warn "    meta { claude_account = \"$CLAUDE_ACCOUNT\" }"
  fi
else
  warn "could not find $NOMAD_CFG to verify claude_account=$CLAUDE_ACCOUNT — set it manually."
fi

# ── 6. Claude login (native execution model — no API keys) ────────────────────
if have claude; then
  if claude --version >/dev/null 2>&1 && [ -f "$HOME/.claude/.credentials.json" ]; then
    log "claude CLI present and appears logged in"
  else
    warn "ACTION NEEDED: run 'claude' once and log in with the $CLAUDE_ACCOUNT account."
  fi
else
  warn "claude CLI not installed — install it, then run 'claude' and log in with $CLAUDE_ACCOUNT."
fi

# ── 7. Self-healing cron (node-doctor) ───────────────────────────────────────
if have crontab; then
  if crontab -l 2>/dev/null | grep -q 'node-doctor.sh'; then
    log "node-doctor cron already installed"
  else
    ( crontab -l 2>/dev/null; echo "0 */8 * * * $DEST/scripts/node-doctor.sh >> /tmp/node-doctor.log 2>&1" ) | crontab -
    log "installed node-doctor cron (every 8h)"
  fi
fi

log "─────────────────────────────────────────────"
log "join complete. verify from any node with: $DEST/scripts/monad nomad nodes"
log "this node should appear as 'ready'. Remaining manual steps (if warned above):"
log "  • finish tailscale auth   • run 'claude' to log in   • set meta.claude_account=$CLAUDE_ACCOUNT and restart nomad"
