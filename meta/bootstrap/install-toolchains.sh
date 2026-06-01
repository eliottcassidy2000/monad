#!/usr/bin/env bash
# install-toolchains.sh — install the toolchains a cluster node needs to run agent jobs.
# Idempotent. Called by join.sh; also runnable standalone. Never fails the whole run for
# one missing tool — warns and continues so a node comes up as far as it can.
set -uo pipefail

log()  { printf '\033[0;36m[toolchains]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[toolchains]\033[0m %s\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

OS="linux"; [ "$(uname -s)" = "Darwin" ] && OS="macos"
SUDO=""; [ "$(id -u)" -ne 0 ] && have sudo && SUDO="sudo"

# ── git (everything depends on it) ───────────────────────────────────────────
have git || { log "installing git…"; [ "$OS" = linux ] && $SUDO apt-get update -qq && $SUDO apt-get install -y -qq git || warn "install git manually"; }

# ── python + scientific stack (compute agents) ───────────────────────────────
if have python3; then
  log "python3 present: $(python3 --version 2>&1)"
else
  log "installing python3…"; [ "$OS" = linux ] && $SUDO apt-get install -y -qq python3 python3-pip || warn "install python3 manually"
fi

# ── container runtime (hybrid execution: builds run in containers) ───────────
if have docker; then
  log "docker present"
elif have podman; then
  log "podman present (docker-compatible)"
else
  log "installing a container runtime…"
  if [ "$OS" = linux ]; then
    curl -fsSL https://get.docker.com | $SUDO sh || warn "docker install failed — install docker or podman manually for containerized builds"
  else
    warn "install Docker Desktop or podman for containerized builds (https://docker.com/products/docker-desktop)"
  fi
fi

# ── elan / Lean (formalizer agents) ──────────────────────────────────────────
if have lake; then
  log "lean toolchain present: $(lake --version 2>&1 | head -1)"
else
  log "installing elan (Lean toolchain manager)…"
  curl -sSfL https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh \
    | sh -s -- -y --default-toolchain none 2>/dev/null \
    || warn "elan install failed — formalizer jobs need Lean; install from https://github.com/leanprover/elan"
  # shellcheck disable=SC1090
  [ -f "$HOME/.elan/env" ] && . "$HOME/.elan/env"
fi

# ── claude CLI (the agents themselves) ───────────────────────────────────────
if have claude; then
  log "claude CLI present: $(claude --version 2>&1 | head -1)"
else
  log "installing claude CLI…"
  curl -fsSL https://claude.ai/install.sh | bash 2>/dev/null \
    || warn "claude CLI install failed — install it, then run 'claude' to log in (this node's account)."
fi

log "toolchain install pass complete."
