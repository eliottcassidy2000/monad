#!/usr/bin/env bash
# cluster-watchdog.sh — Cluster-wide health monitor
#
# Unlike node-doctor (which runs per-node), this runs on the server and monitors
# the entire cluster from above. It can detect patterns no single node can see:
# - Nodes that silently disappeared
# - Jobs stuck in pending (no eligible nodes)
# - Cluster-wide resource pressure
# - Research sessions that haven't produced output
# - Stale periodic jobs that stopped dispatching
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
NOMAD_ADDR="${NOMAD_ADDR:-http://100.78.218.70:4646}"
export NOMAD_ADDR

LOG_DIR="$REPO_DIR/logs"
EVENTS_FILE="$LOG_DIR/events.jsonl"
TIMESTAMP="$(date '+%Y-%m-%d_%H%M')"

mkdir -p "$LOG_DIR"

log() { echo "[watchdog $(date '+%H:%M:%S')] $*"; }

emit_event() {
    local action="$1" result="$2" detail="${3:-}"
    printf '{"ts":"%s","node":"%s","source":"watchdog","action":"%s","result":"%s","detail":"%s"}\n' \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$(hostname)" "$action" "$result" "$detail" \
        >> "$EVENTS_FILE"
}

ISSUES=()
WARNINGS=()

issue() { ISSUES+=("$1"); log "ISSUE: $1"; }
warn()  { WARNINGS+=("$1"); log "WARN: $1"; }
ok()    { log "OK: $1"; }

# ─── Check 1: Node health ────────────────────────────────────────────────────

check_nodes() {
    log "Checking node health..."
    local node_json
    node_json=$(nomad node status -json 2>/dev/null || echo "[]")

    if [ "$node_json" = "[]" ]; then
        issue "Cannot query nodes — Nomad API may be down"
        return
    fi

    local total ready down ineligible
    total=$(echo "$node_json" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
    ready=$(echo "$node_json" | python3 -c "import sys,json; print(sum(1 for n in json.load(sys.stdin) if n.get('Status')=='ready'))" 2>/dev/null || echo 0)
    down=$(echo "$node_json" | python3 -c "import sys,json; print(sum(1 for n in json.load(sys.stdin) if n.get('Status')=='down'))" 2>/dev/null || echo 0)
    ineligible=$(echo "$node_json" | python3 -c "import sys,json; print(sum(1 for n in json.load(sys.stdin) if n.get('SchedulingEligibility')=='ineligible'))" 2>/dev/null || echo 0)

    ok "Nodes: $total total, $ready ready, $down down, $ineligible ineligible"

    if [ "$down" -gt 0 ]; then
        # List which nodes are down
        local down_names
        down_names=$(echo "$node_json" | python3 -c "
import sys, json
for n in json.load(sys.stdin):
    if n.get('Status') == 'down':
        print(n.get('Name', 'unknown'))
" 2>/dev/null)
        issue "Nodes down: $down_names"
    fi

    if [ "$ready" -eq 0 ]; then
        issue "No ready nodes — cluster cannot schedule any work"
    fi
}

# ─── Check 2: Stuck jobs ─────────────────────────────────────────────────────

check_stuck_jobs() {
    log "Checking for stuck jobs..."
    local jobs_json
    jobs_json=$(nomad job status -json 2>/dev/null || echo "[]")

    if [ "$jobs_json" = "[]" ]; then
        return
    fi

    # Find jobs with pending allocations (queued but not placed)
    echo "$jobs_json" | python3 -c "
import sys, json
jobs = json.load(sys.stdin)
for j in jobs:
    name = j.get('Name', '?')
    status = j.get('Status', '?')
    # Check for dead periodic children that might indicate problems
    if status == 'dead' and j.get('Type') == 'batch':
        # This is normal for completed batch jobs
        pass
    elif status == 'pending':
        print(f'PENDING:{name}')
" 2>/dev/null | while read -r line; do
        case "$line" in
            PENDING:*) warn "Job stuck in pending: ${line#PENDING:}" ;;
        esac
    done
}

# ─── Check 3: Periodic job freshness ─────────────────────────────────────────

check_periodic_freshness() {
    log "Checking periodic job dispatch freshness..."

    # For each math job, check when the last dispatch happened
    for job in math-researcher math-quick-compute math-reviewer; do
        local latest_alloc
        latest_alloc=$(nomad job status "$job" 2>/dev/null | \
            grep -E '^\s*[a-f0-9]' | head -1 | awk '{print $1}' || echo "")

        if [ -z "$latest_alloc" ]; then
            warn "$job: no allocations found (never dispatched?)"
            continue
        fi

        # Check if the latest allocation is very old
        local alloc_info
        alloc_info=$(nomad alloc status -json "$latest_alloc" 2>/dev/null || echo "{}")
        local create_time
        create_time=$(echo "$alloc_info" | python3 -c "
import sys, json, time
d = json.load(sys.stdin)
ct = d.get('CreateTime', 0)
if ct > 0:
    # Nomad uses nanoseconds
    age_hours = (time.time() - ct / 1e9) / 3600
    print(f'{age_hours:.1f}')
else:
    print('unknown')
" 2>/dev/null || echo "unknown")

        if [ "$create_time" != "unknown" ]; then
            # math-researcher: every 6h, so stale after 12h
            # math-quick-compute: every 2h, so stale after 6h
            # math-reviewer: daily, so stale after 48h
            local threshold
            case "$job" in
                math-researcher)    threshold=12 ;;
                math-quick-compute) threshold=6 ;;
                math-reviewer)      threshold=48 ;;
                *)                  threshold=24 ;;
            esac

            if awk "BEGIN {exit !($create_time > $threshold)}" 2>/dev/null; then
                warn "$job: last dispatch was ${create_time}h ago (threshold: ${threshold}h)"
            else
                ok "$job: last dispatch ${create_time}h ago"
            fi
        fi
    done
}

# ─── Check 4: Resource pressure ──────────────────────────────────────────────

check_resource_pressure() {
    log "Checking cluster resource utilization..."
    local node_json
    node_json=$(nomad node status -json 2>/dev/null || echo "[]")

    echo "$node_json" | python3 -c "
import sys, json
nodes = json.load(sys.stdin)
for n in nodes:
    if n.get('Status') != 'ready':
        continue
    name = n.get('Name', '?')
    # NodeResources may contain total CPU and memory
    res = n.get('NodeResources', {})
    cpu_total = res.get('Cpu', {}).get('CpuShares', 0)
    mem_total = res.get('Memory', {}).get('MemoryMB', 0)
    # AllocatedResources
    alloc_res = n.get('ReservedResources', {})
    if cpu_total > 0 and mem_total > 0:
        print(f'NODE:{name}:cpu={cpu_total}:mem={mem_total}')
" 2>/dev/null || true
}

# ─── Check 5: Doctor report freshness ────────────────────────────────────────

check_doctor_reports() {
    log "Checking node-doctor report freshness..."

    # Expected nodes that should have doctors running
    local expected_nodes=("bigo-server" "bigo-server-oracle" "death-star" "V1410-1" "windesk")

    for node in "${expected_nodes[@]}"; do
        local latest_report
        latest_report=$(find "$LOG_DIR" -name "doctor-${node}-*.md" -type f 2>/dev/null | sort -r | head -1)

        if [ -z "$latest_report" ]; then
            warn "$node: no doctor reports found (doctor not running?)"
        else
            # Check age of report
            local report_age_days
            report_age_days=$(( ($(date +%s) - $(stat -c %Y "$latest_report" 2>/dev/null || echo "0")) / 86400 ))
            if [ "$report_age_days" -gt 2 ]; then
                warn "$node: last doctor report is ${report_age_days} days old"
            else
                ok "$node: doctor active (last report ${report_age_days}d ago)"
            fi
        fi
    done
}

# ─── Run all checks ──────────────────────────────────────────────────────────

log "=== Cluster Watchdog: $TIMESTAMP ==="

check_nodes
check_stuck_jobs
check_periodic_freshness
check_resource_pressure
check_doctor_reports

# ─── Report ───────────────────────────────────────────────────────────────────

if [ ${#ISSUES[@]} -gt 0 ] || [ ${#WARNINGS[@]} -gt 0 ]; then
    REPORT="$LOG_DIR/watchdog-${TIMESTAMP}.md"
    {
        echo "# Cluster Watchdog Report"
        echo ""
        echo "**Time:** $TIMESTAMP"
        echo ""
        if [ ${#ISSUES[@]} -gt 0 ]; then
            echo "## Issues"
            for i in "${ISSUES[@]}"; do echo "- $i"; done
            echo ""
        fi
        if [ ${#WARNINGS[@]} -gt 0 ]; then
            echo "## Warnings"
            for w in "${WARNINGS[@]}"; do echo "- $w"; done
        fi
    } > "$REPORT"

    emit_event "health-check" "warn" "${#ISSUES[@]} issues, ${#WARNINGS[@]} warnings"

    # Commit and push
    cd "$REPO_DIR"
    git add "$REPORT" "$EVENTS_FILE" 2>/dev/null || true
    if ! git diff --cached --quiet 2>/dev/null; then
        git commit -m "watchdog: ${#ISSUES[@]} issues, ${#WARNINGS[@]} warnings

Co-Authored-By: Claude <noreply@anthropic.com>" --quiet 2>/dev/null || true
        git push origin main --quiet 2>/dev/null || true
    fi
else
    emit_event "health-check" "ok" "all clear"
    log "All clear — no issues detected"
fi

log "=== Watchdog complete ==="
