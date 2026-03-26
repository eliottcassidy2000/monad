#!/usr/bin/env bash
# node-doctor.sh — Local health monitor and self-repair agent
#
# Runs on EACH machine via OS-native cron (NOT Nomad), so it can fix Nomad itself.
# Uses the Pro API key to minimize cost (~3 short sessions/day/node).
#
# Install:
#   Linux:   crontab -e → 0 */8 * * * /path/to/monad/scripts/node-doctor.sh >> /var/log/node-doctor.log 2>&1
#   Windows: schtasks /create /tn "NodeDoctor" /tr "bash /path/to/monad/scripts/node-doctor.sh" /sc daily /st 06:00 /ri 480 /du 24:00
#
# What it does:
#   1. Checks Nomad agent health — restarts if down
#   2. Checks git state — pulls, resolves simple conflicts
#   3. Checks disk space — warns if low
#   4. Checks Tailscale connectivity to server
#   5. If anything is broken, spawns a Claude Code session (Pro key) to diagnose and fix
#   6. Reports status to cluster via git commit
#
# The key insight: if Nomad is dead, Nomad-scheduled jobs can't run. This script
# is the only thing that can resurrect a dead node from the outside.

set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
NOMAD_ADDR="${NOMAD_ADDR:-http://100.78.218.70:4646}"
SERVER_IP="100.78.218.70"
NODE_NAME="$(hostname)"
LOG_DIR="$REPO_DIR/logs"
TIMESTAMP="$(date '+%Y-%m-%d_%H%M')"
DOCTOR_LOG="$LOG_DIR/doctor-${NODE_NAME}-${TIMESTAMP}.md"

export NOMAD_ADDR

mkdir -p "$LOG_DIR"

# ─── Health checks ────────────────────────────────────────────────────────────

ISSUES=()
WARNINGS=()

log() { echo "[$(date '+%H:%M:%S')] $*"; }
issue() { ISSUES+=("$1"); log "ISSUE: $1"; }
warn() { WARNINGS+=("$1"); log "WARN: $1"; }
ok() { log "OK: $1"; }

# Check 1: Is Nomad running?
check_nomad() {
    if command -v nomad &>/dev/null; then
        if nomad node status -self &>/dev/null 2>&1; then
            ok "Nomad agent is running"

            # Check if node is eligible
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

    # Can we pull?
    if git fetch origin main --quiet 2>/dev/null; then
        ok "Git fetch successful"

        local local_rev remote_rev
        local_rev=$(git rev-parse HEAD 2>/dev/null)
        remote_rev=$(git rev-parse origin/main 2>/dev/null)

        if [ "$local_rev" != "$remote_rev" ]; then
            # Try to fast-forward
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

    # Check for uncommitted changes
    local dirty
    dirty=$(git status --porcelain 2>/dev/null | wc -l)
    if [ "$dirty" -gt 0 ]; then
        warn "Git has $dirty uncommitted changes"
    fi
}

# Check 5: Disk space
check_disk() {
    local usage
    # Cross-platform: try df, fall back to Windows methods
    if command -v df &>/dev/null; then
        usage=$(df -h "$REPO_DIR" 2>/dev/null | awk 'NR==2 {print $5}' | tr -d '%')
        if [ -n "$usage" ] && [ "$usage" -gt 90 ]; then
            issue "Disk usage is ${usage}% — critical"
        elif [ -n "$usage" ] && [ "$usage" -gt 80 ]; then
            warn "Disk usage is ${usage}%"
        elif [ -n "$usage" ]; then
            ok "Disk usage: ${usage}%"
        fi
    fi
}

# Check 6: Claude Code availability
check_claude() {
    if command -v claude &>/dev/null; then
        ok "Claude Code CLI is available"
    else
        warn "Claude Code CLI not found — this node can't run research jobs"
    fi
}

# ─── Run all checks ──────────────────────────────────────────────────────────

log "=== Node Doctor: $NODE_NAME ($TIMESTAMP) ==="

check_tailscale
check_server
check_nomad
check_git
check_disk
check_claude

# ─── Write report ────────────────────────────────────────────────────────────

{
    echo "# Node Doctor Report: $NODE_NAME"
    echo ""
    echo "**Time:** $TIMESTAMP"
    echo "**Node:** $NODE_NAME"
    echo ""

    if [ ${#ISSUES[@]} -eq 0 ] && [ ${#WARNINGS[@]} -eq 0 ]; then
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

if [ ${#ISSUES[@]} -gt 0 ]; then
    log "Issues detected — checking if Claude can auto-repair..."

    if command -v claude &>/dev/null; then
        # Claude Code uses the locally authenticated account (Pro or Max)
        # No API key needed — just needs `claude` to be logged in on this machine
        ISSUE_LIST=$(printf '%s\n' "${ISSUES[@]}")

        log "Spawning Claude repair session..."
        claude --print --dangerously-skip-permissions \
            "You are the node-doctor for $NODE_NAME in the Monad cluster.

             These issues were detected:
             $ISSUE_LIST

             Your repo is at: $REPO_DIR
             Nomad server: $SERVER_IP

             For each issue, try to fix it:
             - Nomad not running: check config at the platform-appropriate location, restart it
             - Git conflicts: resolve by keeping both versions, commit
             - Server unreachable: check Tailscale, try reconnect
             - Disk full: clean old logs in $LOG_DIR, clean /tmp

             After fixing, update the doctor log at $DOCTOR_LOG with what you did.
             Keep it brief — you have 5 minutes max." \
            2>&1 | tail -50 >> "$DOCTOR_LOG" || true

        log "Repair session complete"
    else
        log "Claude CLI not available — cannot auto-repair"
    fi
fi

# ─── Report to cluster ───────────────────────────────────────────────────────

# Only commit the report if there were issues (avoid noise from healthy checks)
if [ ${#ISSUES[@]} -gt 0 ] || [ ${#WARNINGS[@]} -gt 0 ]; then
    cd "$REPO_DIR"
    git add "$DOCTOR_LOG" 2>/dev/null || true
    if ! git diff --cached --quiet 2>/dev/null; then
        git commit -m "node-doctor: $NODE_NAME — ${#ISSUES[@]} issues, ${#WARNINGS[@]} warnings

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
