#!/usr/bin/env bash
# Claude cluster monitor - runs every 10 minutes via Nomad
# Invokes Claude Code to inspect cluster state and log findings
set -euo pipefail

export NOMAD_ADDR="${NOMAD_ADDR:-http://100.78.218.70:4646}"

# Load API key from secure file if not already set
if [ -z "${ANTHROPIC_API_KEY:-}" ] && [ -f /etc/monad/anthropic-api-key ]; then
    export ANTHROPIC_API_KEY="$(cat /etc/monad/anthropic-api-key)"
fi

LOG_DIR="/var/log/monad"
mkdir -p "$LOG_DIR"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="$LOG_DIR/monitor-${TIMESTAMP}.log"

CLAUDE_BIN="/home/e/.local/bin/claude"

# Gather raw state for Claude to analyze
STATE=$(cat <<'STATEHEADER'
=== NOMAD SERVER MEMBERS ===
STATEHEADER
)
STATE+=$'\n'"$(nomad server members 2>&1 || echo 'FAILED to query server members')"
STATE+=$'\n\n=== NOMAD NODE STATUS ===\n'
STATE+="$(nomad node status 2>&1 || echo 'FAILED to query node status')"
STATE+=$'\n\n=== NOMAD JOBS ===\n'
STATE+="$(nomad status 2>&1 || echo 'FAILED to query jobs')"
STATE+=$'\n\n=== TAILSCALE STATUS ===\n'
STATE+="$(tailscale status 2>&1 || echo 'FAILED to query tailscale')"
STATE+=$'\n\n=== DISK USAGE ===\n'
STATE+="$(df -h / /opt/nomad/data 2>&1)"
STATE+=$'\n\n=== MEMORY ===\n'
STATE+="$(free -h 2>&1)"
STATE+=$'\n\n=== LOAD ===\n'
STATE+="$(uptime 2>&1)"
STATE+=$'\n\n=== DOCKER STATUS ===\n'
STATE+="$(docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' 2>&1 || echo 'FAILED to query docker')"

# Include previous monitor report if available
PREV_LOG="$(ls -t "$LOG_DIR"/monitor-*.log 2>/dev/null | head -1)"
if [ -n "$PREV_LOG" ] && [ -f "$PREV_LOG" ]; then
    STATE+=$'\n\n=== PREVIOUS MONITOR REPORT ===\n'
    STATE+="$(cat "$PREV_LOG")"
fi

# Write prompt to temp file to avoid quoting issues
PROMPT_FILE="$(mktemp)"
trap 'rm -f "$PROMPT_FILE"' EXIT

cat > "$PROMPT_FILE" <<EOF
You are a cluster health monitor for the monad Nomad cluster. Analyze the following cluster state snapshot and produce a concise status report.

Your report MUST include:
1. **Cluster Health**: Are all expected nodes online and ready? Flag any that are missing, draining, or ineligible.
2. **Job Status**: Are all jobs running as expected? Flag any failed, dead (unexpected), or pending allocations.
3. **Resource Pressure**: Flag any node with high disk usage (>85%), high memory (>85%), or high load.
4. **Tailscale Connectivity**: Are cluster nodes reachable over Tailscale?
5. **Action Items**: List specific things that need attention, or state 'None' if all clear.

If you see the previous monitor report, note any changes since last check.

Keep the report under 40 lines. No preamble, start directly with the status.

--- CLUSTER STATE ---
${STATE}
EOF

echo "=== Claude Monitor Run: $(date -Iseconds) ===" | tee "$LOG_FILE"
echo "" >> "$LOG_FILE"

# Run Claude as user 'e' if we're root (Nomad raw_exec runs as root)
if [ "$(id -u)" = "0" ]; then
    REPORT=$(runuser -u e -- env \
        ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
        HOME="/home/e" \
        PATH="/home/e/.local/bin:/usr/local/bin:/usr/bin:/bin" \
        "$CLAUDE_BIN" -p \
            --model haiku \
            --allowedTools "" \
            --dangerously-skip-permissions \
            "$(cat "$PROMPT_FILE")" 2>&1) || true
else
    REPORT=$("$CLAUDE_BIN" -p \
        --model haiku \
        --allowedTools "" \
        --dangerously-skip-permissions \
        "$(cat "$PROMPT_FILE")" 2>&1) || true
fi

echo "$REPORT" | tee -a "$LOG_FILE"
echo "" >> "$LOG_FILE"
echo "=== End Monitor Run ===" | tee -a "$LOG_FILE"

# Prune old logs (keep last 144 = 24 hours at 10-min intervals)
ls -t "$LOG_DIR"/monitor-*.log 2>/dev/null | tail -n +145 | xargs rm -f 2>/dev/null || true
