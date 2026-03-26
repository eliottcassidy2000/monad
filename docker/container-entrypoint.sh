#!/usr/bin/env bash
# container-entrypoint.sh — Runs inside the monad-claude Docker container
# Called by Nomad Docker driver with env vars set by the job spec
set -euo pipefail

# Setup auth from mounted host credentials
mkdir -p /home/claude/.claude
cp /tmp/host-claude.json /home/claude/.claude.json
cp /tmp/host-credentials.json /home/claude/.claude/.credentials.json

# Get prompt from env (set by Nomad job env block or dispatch payload)
PROMPT="${CLAUDE_PROMPT:-}"
MODEL="${CLAUDE_MODEL:-haiku}"

if [ -z "$PROMPT" ]; then
    # Try reading from dispatch payload
    if [ -f "${NOMAD_TASK_DIR:-/local}/dispatch_payload" ]; then
        PROMPT=$(cat "${NOMAD_TASK_DIR:-/local}/dispatch_payload")
    fi
fi

if [ -z "$PROMPT" ]; then
    echo "ERROR: No prompt provided (set CLAUDE_PROMPT env or dispatch payload)" >&2
    exit 1
fi

# Build claude args
CLAUDE_ARGS=(-p --model "$MODEL" --dangerously-skip-permissions)

# Add system prompt if provided
if [ -n "${CLAUDE_SYSTEM_PROMPT:-}" ]; then
    CLAUDE_ARGS+=(--system-prompt "$CLAUDE_SYSTEM_PROMPT")
fi

# Add tool restrictions if specified (default: no tools)
if [ -n "${CLAUDE_TOOLS:-}" ]; then
    CLAUDE_ARGS+=(--allowedTools "$CLAUDE_TOOLS")
fi

# Run Claude via stdin pipe (avoids arg parser confusion with --allowedTools "")
# Response goes to stdout, captured by Nomad alloc logs
echo "$PROMPT" | exec claude "${CLAUDE_ARGS[@]}"
