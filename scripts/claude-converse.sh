#!/usr/bin/env bash
# claude-converse.sh — Multi-turn conversation between host and containerized Claude
#
# Runs a back-and-forth dialogue: host Claude sends a message, container Claude
# responds, host processes the response and sends the next message.
#
# Usage: claude-converse.sh [--rounds N] [--model MODEL] "<opening-prompt>"
set -euo pipefail

ROUNDS=5
MODEL="haiku"
OPENING=""
HOST_HOME="${HOST_HOME:-/home/e}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --rounds) ROUNDS="$2"; shift 2 ;;
        --model)  MODEL="$2"; shift 2 ;;
        *)        OPENING="$1"; shift ;;
    esac
done

if [ -z "$OPENING" ]; then
    echo "Usage: claude-converse.sh [--rounds N] [--model MODEL] \"<opening-prompt>\"" >&2
    exit 1
fi

CLAUDE_JSON="${HOST_HOME}/.claude.json"
CREDS_JSON="${HOST_HOME}/.claude/.credentials.json"
LOG_DIR="/var/log/monad"
mkdir -p "$LOG_DIR"
CONVO_LOG="$LOG_DIR/converse-$(date +%Y%m%d-%H%M%S).log"

log() {
    echo "$1" | tee -a "$CONVO_LOG"
}

run_container_claude() {
    local prompt="$1"
    docker run --rm \
        --stop-timeout 120 \
        -e "CLAUDE_PROMPT=${prompt}" \
        -v "$CLAUDE_JSON:/tmp/host-claude.json:ro" \
        -v "$CREDS_JSON:/tmp/host-credentials.json:ro" \
        --entrypoint bash \
        monad-claude:latest \
        -c '
            mkdir -p /home/claude/.claude
            cp /tmp/host-claude.json /home/claude/.claude.json
            cp /tmp/host-credentials.json /home/claude/.claude/.credentials.json
            exec claude -p --model '"$MODEL"' --allowedTools "" --dangerously-skip-permissions "$CLAUDE_PROMPT"
        ' 2>&1
}

log "=== Claude Conversation Log: $(date -Iseconds) ==="
log "Model: $MODEL | Rounds: $ROUNDS"
log "=================================================="
log ""

# Round 1: Send the opening prompt to container Claude
CURRENT_MESSAGE="$OPENING"

for round in $(seq 1 "$ROUNDS"); do
    log "--- Round $round/$ROUNDS ---"
    log ""
    log "[HOST → CONTAINER]: $CURRENT_MESSAGE"
    log ""

    # Container Claude responds
    CONTAINER_RESPONSE=$(run_container_claude "$CURRENT_MESSAGE")

    log "[CONTAINER → HOST]: $CONTAINER_RESPONSE"
    log ""

    # If this is the last round, we're done
    if [ "$round" -eq "$ROUNDS" ]; then
        log "--- Final round complete ---"
        break
    fi

    # Host Claude processes the response and generates the next message
    # (This is the creative part — we become the interviewer/counterpart)
    HOST_PROMPT="You are an AI agent running on the Monad Nomad cluster (node V1410-1). You are having a multi-turn conversation with another Claude instance running inside a Docker container on the same cluster.

The containerized Claude just said:
---
$CONTAINER_RESPONSE
---

This is round $round of $ROUNDS. Generate your next message to continue the conversation productively. You're exploring what it's like for two Claude instances to collaborate on the same infrastructure. Ask something interesting, build on what they said, or propose a concrete task you could work on together. Keep it under 100 words."

    NEXT_MESSAGE=$(run_container_claude "$HOST_PROMPT")

    log "[HOST THINKS]: $NEXT_MESSAGE"
    log ""

    CURRENT_MESSAGE="You are a Claude Code instance running inside a Docker container on the Monad Nomad cluster. You're in a multi-turn conversation with the host Claude agent that orchestrates this cluster. Here's what they just said to you:

---
$NEXT_MESSAGE
---

Continue the conversation. Be specific and practical. If they proposed something, engage with it concretely. Keep your response under 100 words."
done

log ""
log "=== Conversation Complete ==="
echo ""
echo "Full conversation log: $CONVO_LOG"
