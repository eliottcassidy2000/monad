#!/usr/bin/env bash
# math-session.sh — Shared launcher for all math research agent sessions
#
# Usage: math-session.sh <role> [clone-depth]
#   role: researcher | compute | reviewer
#   clone-depth: git clone depth (default: 100, use 0 for full clone)
#
# Handles: repo clone, machine ID, day-of-week focus (researcher), prompt loading, cleanup
set -euo pipefail

ROLE="${1:?Usage: math-session.sh <researcher|compute|reviewer>}"
CLONE_DEPTH="${2:-100}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMPT_DIR="$SCRIPT_DIR/prompts"
MATH_REPO="${MATH_REPO_URL:-https://github.com/eliottcassidy2000/math.git}"

# ─── Setup working directory ──────────────────────────────────────────────────

WORK_DIR="/tmp/math-${ROLE}-$$"
trap "rm -rf $WORK_DIR" EXIT

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# Clone the math repo
if [ "$CLONE_DEPTH" -gt 0 ] 2>/dev/null; then
    git clone --depth="$CLONE_DEPTH" "$MATH_REPO" math
else
    git clone "$MATH_REPO" math
fi
cd math

# ─── Register agent ──────────────────────────────────────────────────────────

MACHINE_ID="monad-${ROLE}"
echo "$MACHINE_ID" > .machine-id
if [ -f agents/processor.py ]; then
    python3 agents/processor.py --register 2>/dev/null || true
fi

# ─── Build prompt ─────────────────────────────────────────────────────────────

PROMPT_FILE="$PROMPT_DIR/${ROLE}.md"
if [ "$ROLE" = "researcher" ]; then
    # Substitute day-of-week focus
    PROMPT_FILE="$PROMPT_DIR/researcher.md"
fi

if [ ! -f "$PROMPT_FILE" ]; then
    echo "ERROR: Prompt file not found: $PROMPT_FILE" >&2
    exit 1
fi

PROMPT=$(cat "$PROMPT_FILE")

# For researcher: substitute {{FOCUS}} with day-of-week rotation
if [ "$ROLE" = "researcher" ]; then
    DAY=$(date +%u)
    case $DAY in
        1) FOCUS="Pick the highest-priority red open question from 00-navigation/OPEN-QUESTIONS.md and attempt a proof or significant partial result" ;;
        2) FOCUS="Run computation scripts from 04-computation/ — extend known OEIS sequences, verify conjectures with new data, save ALL outputs via ./run_and_save.sh" ;;
        3) FOCUS="Review hypotheses in 05-knowledge/hypotheses/INDEX.md — pick one and try to prove or definitively refute it with computation or proof" ;;
        4) FOCUS="Read 00-navigation/TANGENTS.md and CONCEPT-MAP.md — develop the most promising cross-domain connection into a concrete result" ;;
        5) FOCUS="Engineering: build or improve a tool — check OPEN-QUESTIONS.md for engineering tasks, improve scripts in 04-computation/, or create a new visualization" ;;
        6) FOCUS="Write-up day: take a result from 05-knowledge/results/ that lacks a clean proof and write a proper theorem file for 01-canon/theorems/" ;;
        7) FOCUS="Free exploration: read CONCEPT-MAP.md and INVESTIGATION-BACKLOG.md, investigate whatever seems most promising, follow your curiosity" ;;
    esac
    PROMPT="${PROMPT//\{\{FOCUS\}\}/$FOCUS}"
fi

# ─── Run Claude session ──────────────────────────────────────────────────────

claude --print --dangerously-skip-permissions "$PROMPT"
