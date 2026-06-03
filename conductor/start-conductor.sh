#!/usr/bin/env bash
# start-conductor.sh — bring up the Cluster Conductor on this node.
#
# Two front doors to one brain:
#   1. the TAILSCALE TEXT GATEWAY  (conductor/gateway.py)  — run in the FOREGROUND
#      so the supervising process (Nomad raw_exec) tracks it and restarts on failure.
#   2. the REMOTE-CONTROL SESSION  (`claude --remote-control cluster-conductor`) — an
#      interactive session the owner attaches to from the Claude app, kept alive in a
#      detached tmux session by a small background watchdog.
#
# Env (all optional):
#   CONDUCTOR_WORKDIR   default: the monad repo root
#   CONDUCTOR_BIND      default: this node's `tailscale ip -4`
#   CONDUCTOR_PORT      default: 8200
#   CONDUCTOR_TOKEN     optional shared bearer token for the gateway
#   ENABLE_REMOTE_CONTROL  "1" (default) to also run the app-facing RC session
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONAD_ROOT="$(cd "$HERE/.." && pwd)"
WORKDIR="${CONDUCTOR_WORKDIR:-$MONAD_ROOT}"
RC_NAME="${CONDUCTOR_RC_NAME:-cluster-conductor}"
RC_TMUX="conductor-rc"
ENABLE_RC="${ENABLE_REMOTE_CONTROL:-1}"

# NOMAD_ADDR for cluster ops, if not already set
if [ -z "${NOMAD_ADDR:-}" ]; then
  MYIP="$(tailscale ip -4 2>/dev/null | head -1)"
  [ -n "$MYIP" ] && export NOMAD_ADDR="http://${MYIP}:4646"
fi

log() { echo "[start-conductor $(date -u +%H:%M:%S)] $*"; }

# ── git push auth (GitOps) via injected GH_TOKEN, if present ───────────────────
if [ -n "${GH_TOKEN:-}" ]; then
  git config --global credential.helper \
    '!f() { echo username=x-access-token; echo "password=$GH_TOKEN"; }; f'
  git config --global user.email "${GIT_EMAIL:-cluster-conductor@monad}"
  git config --global user.name  "${GIT_NAME:-cluster-conductor}"
  git config --global --add safe.directory '*'
  log "git credentials configured (conductor can push to GitOps)"
fi

# ── remote-control watchdog: keep an interactive RC session alive in tmux ──────
rc_watchdog() {
  command -v tmux >/dev/null 2>&1 || { log "tmux not found; remote-control disabled"; return; }
  command -v claude >/dev/null 2>&1 || { log "claude not found; remote-control disabled"; return; }
  while true; do
    if ! tmux has-session -t "$RC_TMUX" 2>/dev/null; then
      log "launching remote-control session '$RC_NAME' in tmux ($RC_TMUX)"
      tmux new-session -d -s "$RC_TMUX" -x 220 -y 50 \
        "cd '$WORKDIR' && exec claude --remote-control '$RC_NAME' --dangerously-skip-permissions"
    fi
    sleep 30
  done
}

if [ "$ENABLE_RC" = "1" ]; then
  rc_watchdog &
  log "remote-control watchdog started (pid $!)"
else
  log "remote-control disabled (ENABLE_REMOTE_CONTROL=$ENABLE_RC)"
fi

# ── the text gateway in the foreground (this is what Nomad supervises) ─────────
log "starting text gateway (workdir=$WORKDIR)"
exec python3 "$HERE/gateway.py"
