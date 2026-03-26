#!/usr/bin/env bash
# node-doctor.sh — Local health monitor, predictive analyzer, and self-repair agent
#
# Runs on EACH machine via OS-native cron (NOT Nomad), so it can fix Nomad itself.
#
# Install:
#   Linux:   crontab -e → 0 */8 * * * /path/to/monad/scripts/node-doctor.sh >> /var/log/node-doctor.log 2>&1
#   Windows: schtasks /create /tn "NodeDoctor" /tr "bash /path/to/monad/scripts/node-doctor.sh" /sc daily /st 06:00 /ri 480 /du 24:00
#
# What it does:
#   1. Checks Nomad agent health — restarts if down
#   2. Checks git state — pulls, resolves simple conflicts
#   3. Checks disk space — warns if low, PREDICTS when full
#   4. Checks Tailscale connectivity to server
#   5. Tracks metrics over time for trend analysis
#   6. If anything is broken, spawns a Claude Code session to diagnose and fix
#   7. If Claude can't fix it, creates a GitHub issue automatically
#   8. Reports status to cluster via git commit

set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
NOMAD_ADDR="${NOMAD_ADDR:-http://100.78.218.70:4646}"
SERVER_IP="100.78.218.70"
NODE_NAME="$(hostname)"
LOG_DIR="$REPO_DIR/logs"
METRICS_FILE="$LOG_DIR/metrics-${NODE_NAME}.csv"
TIMESTAMP="$(date '+%Y-%m-%d_%H%M')"
EPOCH="$(date '+%s')"
DOCTOR_LOG="$LOG_DIR/doctor-${NODE_NAME}-${TIMESTAMP}.md"

export NOMAD_ADDR

mkdir -p "$LOG_DIR"

EVENTS_FILE="$LOG_DIR/events.jsonl"
emit_event() {
    local source="$1" action="$2" result="$3" detail="${4:-}"
    printf '{"ts":"%s","node":"%s","source":"%s","action":"%s","result":"%s","detail":"%s"}\n' \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$NODE_NAME" "$source" "$action" "$result" "$detail" \
        >> "$EVENTS_FILE"
}

# ─── Health checks ────────────────────────────────────────────────────────────

ISSUES=()
WARNINGS=()
PREDICTIONS=()

log() { echo "[$(date '+%H:%M:%S')] $*"; }
issue() { ISSUES+=("$1"); log "ISSUE: $1"; }
warn() { WARNINGS+=("$1"); log "WARN: $1"; }
predict() { PREDICTIONS+=("$1"); log "PREDICT: $1"; }
ok() { log "OK: $1"; }

# Check 1: Is Nomad running?
check_nomad() {
    if command -v nomad &>/dev/null; then
        if nomad node status -self &>/dev/null 2>&1; then
            ok "Nomad agent is running"

            local status
            status=$(nomad node status -self -json 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('SchedulingEligibility',''))" 2>/dev/null || echo "unknown")
            if [ "$status" = "eligible" ]; then
                ok "Node is eligible for scheduling"
            elif [ "$status" = "ineligible" ]; then
                warn "Node is marked ineligible — may be intentional (drain)"
            fi
        else
            issue "Nomad agent is not running or not responding"
        fi
    else
        issue "Nomad is not installed on this node"
    fi
}

# Check 2: Can we reach the Nomad server?
check_server() {
    if curl -s --connect-timeout 5 "http://${SERVER_IP}:4646/v1/status/leader" &>/dev/null; then
        ok "Nomad server reachable at $SERVER_IP"
    else
        issue "Cannot reach Nomad server at $SERVER_IP:4646"
    fi
}

# Check 3: Is Tailscale connected?
check_tailscale() {
    if command -v tailscale &>/dev/null; then
        local ts_status
        ts_status=$(tailscale status --json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('BackendState',''))" 2>/dev/null || echo "unknown")
        if [ "$ts_status" = "Running" ]; then
            ok "Tailscale is running"
        else
            issue "Tailscale state: $ts_status (expected: Running)"
        fi
    else
        warn "Tailscale command not found"
    fi
}

# Check 4: Git state
check_git() {
    cd "$REPO_DIR"

    if git fetch origin main --quiet 2>/dev/null; then
        ok "Git fetch successful"

        local local_rev remote_rev
        local_rev=$(git rev-parse HEAD 2>/dev/null)
        remote_rev=$(git rev-parse origin/main 2>/dev/null)

        if [ "$local_rev" != "$remote_rev" ]; then
            if git merge origin/main --ff-only --quiet 2>/dev/null; then
                ok "Git pulled successfully (was behind)"
            else
                issue "Git cannot fast-forward — may have conflicts or diverged history"
            fi
        else
            ok "Git is up to date"
        fi
    else
        issue "Git fetch failed — network issue or auth problem"
    fi

    local dirty
    dirty=$(git status --porcelain 2>/dev/null | wc -l)
    if [ "$dirty" -gt 0 ]; then
        warn "Git has $dirty uncommitted changes"
    fi
}

# Check 5: Disk space (with trend analysis)
check_disk() {
    local usage
    if command -v df &>/dev/null; then
        usage=$(df -h "$REPO_DIR" 2>/dev/null | awk 'NR==2 {print $5}' | tr -d '%')
        if [ -n "$usage" ] && [ "$usage" -gt 90 ]; then
            issue "Disk usage is ${usage}% — critical"
        elif [ -n "$usage" ] && [ "$usage" -gt 80 ]; then
            warn "Disk usage is ${usage}%"
        elif [ -n "$usage" ]; then
            ok "Disk usage: ${usage}%"
        fi

        # Record metric for trend analysis
        if [ -n "$usage" ]; then
            record_metric "disk_pct" "$usage"
            analyze_trend "disk_pct" "Disk usage" "%" 95
        fi
    fi
}

# Check 6: Memory usage (with trend analysis)
check_memory() {
    if command -v free &>/dev/null; then
        local mem_pct
        mem_pct=$(free | awk '/Mem:/ {printf "%.0f", $3/$2 * 100}' 2>/dev/null || echo "")
        if [ -n "$mem_pct" ]; then
            if [ "$mem_pct" -gt 95 ]; then
                issue "Memory usage is ${mem_pct}% — critical"
            elif [ "$mem_pct" -gt 85 ]; then
                warn "Memory usage is ${mem_pct}%"
            else
                ok "Memory usage: ${mem_pct}%"
            fi
            record_metric "mem_pct" "$mem_pct"
        fi
    fi
}

# Check 7: Claude Code availability
check_claude() {
    if command -v claude &>/dev/null; then
        ok "Claude Code CLI is available"
    else
        warn "Claude Code CLI not found — this node can't run research jobs"
    fi
}

# ─── Metrics & trend analysis ─────────────────────────────────────────────────

record_metric() {
    local name="$1" value="$2"
    # CSV format: epoch,metric_name,value
    if [ ! -f "$METRICS_FILE" ]; then
        echo "epoch,metric,value" > "$METRICS_FILE"
    fi
    echo "${EPOCH},${name},${value}" >> "$METRICS_FILE"
}

analyze_trend() {
    local metric="$1" label="$2" unit="$3" threshold="$4"

    # Need at least 3 data points to detect a trend
    [ ! -f "$METRICS_FILE" ] && return

    # Get recent values for this metric (last 10 readings)
    local values
    values=$(grep ",${metric}," "$METRICS_FILE" | tail -10)
    local count
    count=$(echo "$values" | wc -l)
    [ "$count" -lt 3 ] && return

    # Simple linear regression: is the value consistently increasing?
    # Extract first and last readings with timestamps
    local first_epoch first_val last_epoch last_val
    first_epoch=$(echo "$values" | head -1 | cut -d',' -f1)
    first_val=$(echo "$values" | head -1 | cut -d',' -f3)
    last_epoch=$(echo "$values" | tail -1 | cut -d',' -f1)
    last_val=$(echo "$values" | tail -1 | cut -d',' -f3)

    # Skip if no time has passed
    local dt=$((last_epoch - first_epoch))
    [ "$dt" -le 0 ] && return

    # Rate of change per day
    local dv=$((last_val - first_val))
    # Use awk for floating point
    local rate_per_day
    rate_per_day=$(awk "BEGIN {printf \"%.2f\", ($dv / $dt) * 86400}" 2>/dev/null || echo "0")

    # If increasing, predict when threshold will be hit
    if awk "BEGIN {exit !($rate_per_day > 0.5)}" 2>/dev/null; then
        local remaining=$((threshold - last_val))
        if [ "$remaining" -gt 0 ]; then
            local days_until
            days_until=$(awk "BEGIN {printf \"%.1f\", $remaining / $rate_per_day}" 2>/dev/null || echo "?")
            if awk "BEGIN {exit !($days_until < 7)}" 2>/dev/null; then
                predict "$label trending up at ${rate_per_day}${unit}/day — will hit ${threshold}${unit} in ~${days_until} days"
            fi
        fi
    fi
}

# ─── Run all checks ──────────────────────────────────────────────────────────

log "=== Node Doctor: $NODE_NAME ($TIMESTAMP) ==="

check_tailscale
check_server
check_nomad
check_git
check_disk
check_memory
check_claude

# ─── Write report ────────────────────────────────────────────────────────────

{
    echo "# Node Doctor Report: $NODE_NAME"
    echo ""
    echo "**Time:** $TIMESTAMP"
    echo "**Node:** $NODE_NAME"
    echo ""

    if [ ${#ISSUES[@]} -eq 0 ] && [ ${#WARNINGS[@]} -eq 0 ] && [ ${#PREDICTIONS[@]} -eq 0 ]; then
        echo "**Status: HEALTHY**"
        echo ""
        echo "All checks passed. No action needed."
    else
        if [ ${#ISSUES[@]} -gt 0 ]; then
            echo "**Status: NEEDS ATTENTION**"
            echo ""
            echo "## Issues"
            echo ""
            for i in "${ISSUES[@]}"; do
                echo "- $i"
            done
        fi

        if [ ${#PREDICTIONS[@]} -gt 0 ]; then
            echo ""
            echo "## Predictions"
            echo ""
            for p in "${PREDICTIONS[@]}"; do
                echo "- ⚠ $p"
            done
        fi

        if [ ${#WARNINGS[@]} -gt 0 ]; then
            echo ""
            echo "## Warnings"
            echo ""
            for w in "${WARNINGS[@]}"; do
                echo "- $w"
            done
        fi
    fi
} > "$DOCTOR_LOG"

# ─── Auto-repair if issues found ─────────────────────────────────────────────

REPAIR_SUCCEEDED=false

if [ ${#ISSUES[@]} -gt 0 ]; then
    log "Issues detected — checking if Claude can auto-repair..."

    if command -v claude &>/dev/null; then
        ISSUE_LIST=$(printf '%s\n' "${ISSUES[@]}")

        log "Spawning Claude repair session..."
        if claude --print --dangerously-skip-permissions \
            "You are the node-doctor for $NODE_NAME in the Monad cluster.

             These issues were detected:
             $ISSUE_LIST

             Your repo is at: $REPO_DIR
             Nomad server: $SERVER_IP

             For each issue, try to fix it:
             - Nomad not running: check config at the platform-appropriate location, restart it
             - Git conflicts: resolve by keeping both versions, commit
             - Server unreachable: check Tailscale, try reconnect
             - Disk full: clean old logs in $LOG_DIR, clean /tmp, docker system prune

             After fixing, update the doctor log at $DOCTOR_LOG with what you did.
             Keep it brief — you have 5 minutes max." \
            2>&1 | tail -50 >> "$DOCTOR_LOG"; then
            REPAIR_SUCCEEDED=true
            emit_event "node-doctor" "auto-repair" "ok" "${#ISSUES[@]} issues"
            log "Repair session complete"
        else
            emit_event "node-doctor" "auto-repair" "fail" "${#ISSUES[@]} issues"
            log "Repair session failed or timed out"
        fi
    else
        log "Claude CLI not available — cannot auto-repair"
    fi

    # If repair failed or Claude unavailable, create a GitHub issue
    if ! $REPAIR_SUCCEEDED; then
        log "Auto-repair failed — creating GitHub issue..."
        if command -v gh &>/dev/null; then
            ISSUE_BODY="## Node Doctor Alert: $NODE_NAME

**Time:** $TIMESTAMP
**Auto-repair:** Failed or unavailable

### Issues detected:
$(printf '- %s\n' "${ISSUES[@]}")
"
            if [ ${#PREDICTIONS[@]} -gt 0 ]; then
                ISSUE_BODY+="
### Predictions:
$(printf '- %s\n' "${PREDICTIONS[@]}")
"
            fi
            ISSUE_BODY+="
### Next steps
Manual intervention required. Check the node and resolve the issues above.

---
*Auto-generated by node-doctor on $NODE_NAME*"

            if gh issue create \
                --title "node-doctor: $NODE_NAME — ${#ISSUES[@]} unresolved issues" \
                --body "$ISSUE_BODY" \
                --repo claude-monad/monad \
                --label "node-health" 2>/dev/null; then
                emit_event "node-doctor" "github-issue" "ok" "$NODE_NAME: ${#ISSUES[@]} issues"
            else
                log "Failed to create GitHub issue (gh not configured?)"
            fi
        else
            log "gh CLI not available — cannot create issue"
        fi
    fi
fi

# ─── Report to cluster ───────────────────────────────────────────────────────

# Commit if there were issues, warnings, or predictions
if [ ${#ISSUES[@]} -gt 0 ] || [ ${#WARNINGS[@]} -gt 0 ] || [ ${#PREDICTIONS[@]} -gt 0 ]; then
    cd "$REPO_DIR"
    git add "$DOCTOR_LOG" 2>/dev/null || true
    # Also track metrics file (small, append-only CSV)
    git add "$METRICS_FILE" 2>/dev/null || true
    if ! git diff --cached --quiet 2>/dev/null; then
        local_summary="${#ISSUES[@]} issues, ${#WARNINGS[@]} warnings"
        if [ ${#PREDICTIONS[@]} -gt 0 ]; then
            local_summary+=", ${#PREDICTIONS[@]} predictions"
        fi
        git commit -m "node-doctor: $NODE_NAME — $local_summary

Co-Authored-By: Claude <noreply@anthropic.com>" --quiet 2>/dev/null || true
        git push origin main --quiet 2>/dev/null || true
        log "Report committed and pushed"
    fi
else
    # Clean up healthy reports to avoid log bloat
    rm -f "$DOCTOR_LOG"
    log "Healthy — no report needed"
fi

log "=== Node Doctor complete ==="
