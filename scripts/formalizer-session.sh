#!/usr/bin/env bash
# formalizer-session.sh — launcher for the Lean formalizer agent.
#
# Mirrors math-session.sh, but clones the Lean formalization repo (claude-monad/math-lean)
# instead of the informal math repo, and runs the formalizer prompt. The agent pulls its own
# candidates from the informal repo via the repo's sync-candidates.sh.
#
# Usage: formalizer-session.sh [clone-depth]   (default depth: full, Lean repo is small)
set -euo pipefail

CLONE_DEPTH="${1:-0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMPT_FILE="$SCRIPT_DIR/prompts/formalizer.md"
LEAN_REPO="${LEAN_REPO_URL:-https://github.com/claude-monad/math-lean.git}"

WORK_DIR="/tmp/math-lean-formalizer-$$"
trap "rm -rf $WORK_DIR" EXIT
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# Clone the Lean repo (small; full clone by default)
if [ "$CLONE_DEPTH" -gt 0 ] 2>/dev/null; then
    git clone --depth="$CLONE_DEPTH" "$LEAN_REPO" math-lean
else
    git clone "$LEAN_REPO" math-lean
fi
cd math-lean

echo "monad-formalizer" > .machine-id

[ -f "$PROMPT_FILE" ] || { echo "ERROR: prompt not found: $PROMPT_FILE" >&2; exit 1; }
PROMPT="$(cat "$PROMPT_FILE")"

claude --print --dangerously-skip-permissions "$PROMPT"
