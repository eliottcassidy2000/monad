#!/usr/bin/env bash
# Monad GitOps Sync — with drift detection and canary rollback
#
# Only re-applies jobs whose HCL files actually changed (SHA256 tracking).
# After applying a changed job, verifies the allocation is healthy.
# If the new version fails, reverts to the previous version automatically.
#
# State file: .sync-state (JSON map of job_name → sha256)
set -euo pipefail

# Auto-detect: prefer env var, then script's parent dir, then legacy path
if [ -n "${MONAD_REPO_DIR:-}" ]; then
    REPO_DIR="$MONAD_REPO_DIR"
elif [ -d "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.git" ]; then
    REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
else
    REPO_DIR="/home/${USER:-bigo}/monad"
fi
NOMAD_ADDR="${NOMAD_ADDR:-http://100.78.218.70:4646}"
export NOMAD_ADDR

JOBS_DIR="$REPO_DIR/jobs"
STATE_FILE="$REPO_DIR/.sync-state"
CANARY_WAIT="${SYNC_CANARY_WAIT:-30}"  # seconds to wait for health check

log() { echo "[monad-sync $(date '+%H:%M:%S')] $*"; }

EVENTS_FILE="$REPO_DIR/logs/events.jsonl"
emit_event() {
    local source="$1" action="$2" result="$3" detail="${4:-}"
    mkdir -p "$(dirname "$EVENTS_FILE")"
    printf '{"ts":"%s","node":"%s","source":"%s","action":"%s","result":"%s","detail":"%s"}\n' \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$(hostname)" "$source" "$action" "$result" "$detail" \
        >> "$EVENTS_FILE"
}

# ─── Pull latest ──────────────────────────────────────────────────────────────

cd "$REPO_DIR"
git fetch origin main --quiet 2>/dev/null || true
LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse origin/main 2>/dev/null || echo "$LOCAL")

if [ "$LOCAL" != "$REMOTE" ]; then
    log "Pulling updates ($(echo "$LOCAL" | head -c 7) → $(echo "$REMOTE" | head -c 7))"
    git reset --hard origin/main --quiet
else
    log "Already up to date ($(echo "$LOCAL" | head -c 7))"
fi

# ─── Load previous state ─────────────────────────────────────────────────────

declare -A prev_hashes
if [ -f "$STATE_FILE" ]; then
    while IFS='=' read -r key val; do
        [ -n "$key" ] && prev_hashes["$key"]="$val"
    done < "$STATE_FILE"
fi

# ─── Discover desired jobs ────────────────────────────────────────────────────

declare -A desired_jobs
declare -A current_hashes
CHANGED=()
UNCHANGED=()
ERRORS=()

if [ -d "$JOBS_DIR" ]; then
    for f in "$JOBS_DIR"/*.hcl; do
        [ -f "$f" ] || continue
        job_name=$(grep -m1 '^job\s' "$f" | sed 's/job\s*"\([^"]*\)".*/\1/' || basename "$f" .hcl)
        desired_jobs["$job_name"]="$f"

        # Compute hash for drift detection
        file_hash=$(sha256sum "$f" | awk '{print $1}')
        current_hashes["$job_name"]="$file_hash"

        if [ "${prev_hashes[$job_name]:-}" = "$file_hash" ]; then
            UNCHANGED+=("$job_name")
        else
            CHANGED+=("$job_name")
        fi
    done
fi

# ─── Get running jobs from Nomad ──────────────────────────────────────────────

declare -A running_jobs
while IFS= read -r line; do
    [ -z "$line" ] && continue
    job_id=$(echo "$line" | awk '{print $1}')
    [ "$job_id" = "ID" ] && continue
    running_jobs["$job_id"]=1
done < <(nomad job status -short 2>/dev/null || true)

# ─── Apply only changed jobs ─────────────────────────────────────────────────

if [ ${#UNCHANGED[@]} -gt 0 ]; then
    log "Unchanged (skipping): ${UNCHANGED[*]}"
fi

for job_name in "${CHANGED[@]}"; do
    job_file="${desired_jobs[$job_name]}"
    log "Drift detected: $job_name — applying..."

    # Save the previous version for rollback (if it exists in git history)
    prev_version=""
    if [ -n "${prev_hashes[$job_name]:-}" ]; then
        prev_version=$(git show "HEAD~1:jobs/$(basename "$job_file")" 2>/dev/null || true)
    fi

    if nomad job run "$job_file" 2>&1; then
        log "  ✓ $job_name submitted"

        # Canary check: wait and verify the job is healthy
        # Only for service/system jobs (batch/periodic don't stay "running")
        job_type=$(grep -m1 'type\s*=' "$job_file" | sed 's/.*"\(.*\)".*/\1/' || echo "service")
        if [ "$job_type" = "service" ] || [ "$job_type" = "system" ]; then
            log "  ⏳ Canary check ($CANARY_WAIT s)..."
            sleep "$CANARY_WAIT"

            # Check if the latest allocation is running
            alloc_status=$(nomad job status "$job_name" 2>/dev/null | \
                grep -E '^\s*[a-f0-9]' | head -1 | awk '{print $6}' || echo "unknown")

            if [ "$alloc_status" = "running" ]; then
                log "  ✓ $job_name canary passed (alloc: running)"
                emit_event "sync" "canary-pass" "ok" "$job_name"
            else
                log "  ✗ $job_name canary FAILED (alloc: $alloc_status)"
                emit_event "sync" "canary-fail" "fail" "$job_name ($alloc_status)"
                ERRORS+=("$job_name: canary failed ($alloc_status)")

                # Attempt rollback if we have a previous version
                if [ -n "$prev_version" ]; then
                    log "  ↩ Rolling back $job_name..."
                    rollback_file="/tmp/monad-rollback-${job_name}.hcl"
                    echo "$prev_version" > "$rollback_file"
                    if nomad job run "$rollback_file" 2>&1; then
                        emit_event "sync" "rollback" "rollback" "$job_name"
                        log "  ✓ Rollback applied for $job_name"
                        # Restore previous hash so next sync retries
                        current_hashes["$job_name"]="${prev_hashes[$job_name]}"
                    else
                        log "  ✗ Rollback also failed for $job_name"
                    fi
                    rm -f "$rollback_file"
                fi
            fi
        else
            log "  ℹ $job_name is $job_type — skipping canary"
        fi
    else
        log "  ✗ $job_name failed to submit"
        ERRORS+=("$job_name: submission failed")
    fi
done

# Also apply any jobs that are in git but not running (new jobs, or recovered)
for job_name in "${!desired_jobs[@]}"; do
    if [ -z "${running_jobs[$job_name]+x}" ]; then
        # Check if we already handled it in CHANGED
        already_handled=false
        for c in "${CHANGED[@]}"; do
            [ "$c" = "$job_name" ] && already_handled=true && break
        done
        if ! $already_handled; then
            job_file="${desired_jobs[$job_name]}"
            log "Not running, submitting: $job_name"
            if nomad job run "$job_file" 2>&1; then
                log "  ✓ $job_name submitted"
            else
                log "  ✗ $job_name failed"
                ERRORS+=("$job_name: submission failed (recovery)")
            fi
        fi
    fi
done

# ─── Stop jobs not in git ─────────────────────────────────────────────────────

for job_id in "${!running_jobs[@]}"; do
    if [ -z "${desired_jobs[$job_id]+x}" ]; then
        # Don't stop the sync job or its periodic children
        [[ "$job_id" == monad-sync* ]] && continue
        [[ "$job_id" == *"/periodic-"* ]] && continue

        log "Stopping removed job: $job_id"
        nomad job stop "$job_id" 2>&1 || log "  ✗ Failed to stop $job_id"
    fi
done

# ─── Save state ───────────────────────────────────────────────────────────────

{
    for job_name in "${!current_hashes[@]}"; do
        echo "${job_name}=${current_hashes[$job_name]}"
    done
} > "$STATE_FILE"

# ─── Summary ──────────────────────────────────────────────────────────────────

log "Sync complete. Changed: ${#CHANGED[@]}, Unchanged: ${#UNCHANGED[@]}, Errors: ${#ERRORS[@]}"
if [ ${#ERRORS[@]} -gt 0 ]; then
    log "ERRORS:"
    for e in "${ERRORS[@]}"; do
        log "  - $e"
    done
fi
