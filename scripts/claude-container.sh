#!/usr/bin/env bash
# claude-container.sh — Run Claude Code inside a Docker container
#
# Usage: claude-container.sh [options] "<prompt>"
#   Options:
#     --model <model>       Model to use (default: haiku)
#     --tools <tools>       Allowed tools (default: "" for none)
#     --system <prompt>     System prompt override
#     --name <name>         Session name for logging
#     --timeout <seconds>   Container timeout (default: 300)
#
# Requires: monad-claude:latest Docker image
# Auth: Mounts host OAuth credentials (copied into container at startup)
set -euo pipefail

MODEL="haiku"
TOOLS=""
SYSTEM_PROMPT=""
SESSION_NAME="container-claude"
TIMEOUT=300
PROMPT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --model)   MODEL="$2"; shift 2 ;;
        --tools)   TOOLS="$2"; shift 2 ;;
        --system)  SYSTEM_PROMPT="$2"; shift 2 ;;
        --name)    SESSION_NAME="$2"; shift 2 ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        *)         PROMPT="$1"; shift ;;
    esac
done

if [ -z "$PROMPT" ]; then
    echo "Usage: claude-container.sh [options] \"<prompt>\"" >&2
    exit 1
fi

# Find host credentials
HOST_HOME="${HOST_HOME:-/home/e}"
CLAUDE_JSON="${HOST_HOME}/.claude.json"
CREDS_JSON="${HOST_HOME}/.claude/.credentials.json"

if [ ! -f "$CLAUDE_JSON" ] || [ ! -f "$CREDS_JSON" ]; then
    echo "ERROR: Claude credentials not found at $CLAUDE_JSON or $CREDS_JSON" >&2
    exit 1
fi

# Build claude args inside the container script
CLAUDE_OPTS="--model $MODEL --dangerously-skip-permissions"
[ -n "$TOOLS" ] && CLAUDE_OPTS+=" --allowedTools '$TOOLS'"
[ -n "$SYSTEM_PROMPT" ] && CLAUDE_OPTS+=" --system-prompt \"\$SYSTEM_PROMPT\""

# Run containerized Claude
# Pass prompt via env var to avoid quoting/permission issues with file mounts
docker run --rm \
    --name "${SESSION_NAME}-$$" \
    --stop-timeout "$TIMEOUT" \
    -e "CLAUDE_PROMPT=${PROMPT}" \
    -e "SYSTEM_PROMPT=${SYSTEM_PROMPT}" \
    -v "$CLAUDE_JSON:/tmp/host-claude.json:ro" \
    -v "$CREDS_JSON:/tmp/host-credentials.json:ro" \
    --entrypoint bash \
    monad-claude:latest \
    -c "
        mkdir -p /home/claude/.claude
        cp /tmp/host-claude.json /home/claude/.claude.json
        cp /tmp/host-credentials.json /home/claude/.claude/.credentials.json
        exec claude -p $CLAUDE_OPTS \"\$CLAUDE_PROMPT\"
    "
