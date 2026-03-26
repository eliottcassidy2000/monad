#!/usr/bin/env bash
# Monad GitOps Sync
# Pulls latest from git and reconciles Nomad jobs to match jobs/ directory.
# - New .hcl files in jobs/ → nomad job run
# - Modified .hcl files → nomad job run (plan + apply)
# - Removed .hcl files → nomad job stop
set -euo pipefail

REPO_DIR="${MONAD_REPO_DIR:-/home/bigo/Documents/monad}"
NOMAD_ADDR="${NOMAD_ADDR:-http://100.78.218.70:4646}"
export NOMAD_ADDR

JOBS_DIR="$REPO_DIR/jobs"
STATE_FILE="$REPO_DIR/.sync-state"

log() { echo "[monad-sync $(date '+%H:%M:%S')] $*"; }

# Pull latest
cd "$REPO_DIR"
git fetch origin main --quiet 2>/dev/null || true
LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse origin/main 2>/dev/null || echo "$LOCAL")

if [ "$LOCAL" != "$REMOTE" ]; then
    log "Pulling updates ($LOCAL → $REMOTE)"
    git reset --hard origin/main --quiet
else
    log "Already up to date ($LOCAL)"
fi

# Get desired jobs from git
declare -A desired_jobs
if [ -d "$JOBS_DIR" ]; then
    for f in "$JOBS_DIR"/*.hcl; do
        [ -f "$f" ] || continue
        # Extract job name from the file (first job stanza)
        job_name=$(grep -m1 '^job\s' "$f" | sed 's/job\s*"\([^"]*\)".*/\1/' || basename "$f" .hcl)
        desired_jobs["$job_name"]="$f"
    done
fi

# Get running jobs from Nomad
declare -A running_jobs
while IFS= read -r line; do
    [ -z "$line" ] && continue
    job_id=$(echo "$line" | awk '{print $1}')
    [ "$job_id" = "ID" ] && continue  # skip header
    running_jobs["$job_id"]=1
done < <(nomad job status -short 2>/dev/null || true)

# Apply desired jobs
for job_name in "${!desired_jobs[@]}"; do
    job_file="${desired_jobs[$job_name]}"
    log "Applying job: $job_name ($job_file)"
    if nomad job run "$job_file" 2>&1; then
        log "  ✓ $job_name applied"
    else
        log "  ✗ $job_name failed"
    fi
done

# Stop jobs that are running but not in git
for job_id in "${!running_jobs[@]}"; do
    if [ -z "${desired_jobs[$job_id]+x}" ]; then
        # Don't stop the sync job or its periodic children
        if [[ "$job_id" == monad-sync* ]]; then
            continue
        fi
        # Skip periodic child dispatches (contain /periodic-)
        if [[ "$job_id" == *"/periodic-"* ]]; then
            continue
        fi
        log "Stopping removed job: $job_id"
        nomad job stop "$job_id" 2>&1 || log "  ✗ Failed to stop $job_id"
    fi
done

log "Sync complete. Desired: ${#desired_jobs[@]} jobs, Running: ${#running_jobs[@]} jobs"
