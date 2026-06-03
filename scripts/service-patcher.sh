#!/usr/bin/env bash
set -euo pipefail

# ── Service Patcher — zero-downtime rolling updates ──────────────────
#
# Checks all Docker-based Nomad jobs for newer image versions.
# If a newer digest is available, triggers a rolling restart.
# Nomad's update stanza + health checks handle zero-downtime.
#
# Runs as a daily periodic Nomad job (service-patcher.hcl).
# ────────────────────────────────────────────────────────────────────

REPO_DIR="${MONAD_REPO_DIR:-$HOME/monad}"
# Auto-discover Nomad
if [ -z "${NOMAD_ADDR:-}" ]; then
  _my_ip="$(tailscale ip -4 2>/dev/null | head -1 || echo "127.0.0.1")"
  if curl -s --connect-timeout 1 "http://${_my_ip}:4646/v1/status/leader" >/dev/null 2>&1; then
    NOMAD_ADDR="http://${_my_ip}:4646"
  else
    for _ip in $(tailscale status 2>/dev/null | grep -v offline | grep -v '^#' | awk '/^100\./{print $1}'); do
      [ "$_ip" = "$_my_ip" ] && continue
      if curl -s --connect-timeout 1 "http://${_ip}:4646/v1/status/leader" >/dev/null 2>&1; then
        NOMAD_ADDR="http://${_ip}:4646"; break
      fi
    done
  fi
  NOMAD_ADDR="${NOMAD_ADDR:-http://${_my_ip}:4646}"
fi
EVENTS_FILE="$REPO_DIR/logs/events.jsonl"
export NOMAD_ADDR

log() { echo "[patcher $(date '+%H:%M:%S')] $*"; }

emit_event() {
    local action="$1" result="$2" detail="${3:-}"
    mkdir -p "$(dirname "$EVENTS_FILE")"
    printf '{"ts":"%s","node":"%s","source":"patcher","action":"%s","result":"%s","detail":"%s"}\n' \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$(hostname)" "$action" "$result" "$detail" \
        >> "$EVENTS_FILE"
}

# Docker images used by our jobs (image → job name)
declare -A IMAGES
IMAGES["hashicorp/vault:1.15"]="vault"
IMAGES["redis:7-alpine"]="redis"
IMAGES["postgres:16-alpine"]="postgres"
IMAGES["traefik:v3.0"]="traefik"
IMAGES["minio/minio:latest"]="minio-storage"

UPDATED=0
FAILED=0

for image in "${!IMAGES[@]}"; do
    job="${IMAGES[$image]}"
    log "Checking $image ($job)..."

    # Get current local digest
    OLD_DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' "$image" 2>/dev/null | cut -d@ -f2 || echo "none")

    # Pull latest
    if ! docker pull "$image" --quiet >/dev/null 2>&1; then
        log "  WARN: failed to pull $image"
        FAILED=$((FAILED + 1))
        continue
    fi

    # Get new digest
    NEW_DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' "$image" 2>/dev/null | cut -d@ -f2 || echo "none")

    if [ "$OLD_DIGEST" = "$NEW_DIGEST" ]; then
        log "  Up to date (${NEW_DIGEST:0:16}...)"
        continue
    fi

    log "  New version available! Rolling restart of '$job'..."
    log "    old: ${OLD_DIGEST:0:32}..."
    log "    new: ${NEW_DIGEST:0:32}..."

    # Check if the job is running
    JOB_STATUS=$(nomad job status -short "$job" 2>/dev/null | tail -1 | awk '{print $4}' || echo "unknown")
    if [ "$JOB_STATUS" != "running" ]; then
        log "  Job '$job' not running ($JOB_STATUS), skipping restart"
        continue
    fi

    # Trigger a rolling restart via alloc restart
    # This forces Nomad to pull the new image and apply update stanza
    JOB_FILE="$REPO_DIR/jobs/${job}.hcl"
    if [ -f "$JOB_FILE" ]; then
        if nomad job run "$JOB_FILE" 2>&1; then
            log "  Redeployed $job"
            emit_event "patch" "ok" "$job: $image updated ($OLD_DIGEST -> $NEW_DIGEST)"
            UPDATED=$((UPDATED + 1))
        else
            log "  FAILED to redeploy $job"
            emit_event "patch" "fail" "$job: redeploy failed"
            FAILED=$((FAILED + 1))
        fi
    else
        log "  No job file at $JOB_FILE, skipping"
    fi
done

# Prune old images to reclaim disk
log "Pruning unused Docker images..."
docker image prune -f --filter "until=168h" >/dev/null 2>&1 || true

log "Patch complete. Updated: $UPDATED, Failed: $FAILED"
