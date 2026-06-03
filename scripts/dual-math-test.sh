#!/usr/bin/env bash
# dual-math-test.sh — capability test: run an autonomous math session with Claude AND one with
# Codex, then report to the cluster how both went. Driven on a schedule by jobs/dual-math-test.hcl.
#
# "Report to the cluster" = a line in logs/events.jsonl + a full markdown report in
# logs/cap-tests/, committed and pushed so every node sees it.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
[ -d "$REPO/.git" ] || REPO="${MONAD_REPO_DIR:-$HOME/monad}"
EVENTS="$REPO/logs/events.jsonl"
OUT_DIR="$REPO/logs/cap-tests"; mkdir -p "$OUT_DIR"
export HOME="${HOME:-/home/e}"
export PATH="$PATH:/usr/bin:/usr/local/bin:$HOME/bin"
STAMP="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo run)"
NODE="$(hostname)"
REPORT="$OUT_DIR/dual-math-$STAMP-$NODE.md"
WORK="/tmp/dual-math-$$"; mkdir -p "$WORK/claude" "$WORK/codex"; trap 'rm -rf "$WORK"' EXIT

PROMPT='You are running a brief AUTONOMOUS MATH SESSION for the monad research cluster (a capability test). In at most ~3 minutes, pick ONE small, concrete, self-contained question in tournament theory (complete directed graphs / Hamiltonian path counts) or closely related combinatorics, work it out yourself from first principles, and report. Keep it self-contained — no external resources needed. End with EXACTLY these two lines and nothing after:
RESULT: <one-sentence statement of what you worked out>
CONFIDENCE: <high|medium|low> — <short why>'

# ── Claude session ──────────────────────────────────────────────────────────
if command -v claude >/dev/null 2>&1; then
  c_start=$(date +%s)
  CLAUDE_OUT="$(cd "$WORK/claude" && timeout 240 claude --print --dangerously-skip-permissions "$PROMPT" </dev/null 2>&1)"
  c_rc=$?; c_dur=$(( $(date +%s) - c_start ))
else
  CLAUDE_OUT="claude CLI not found on $NODE"; c_rc=127; c_dur=0
fi

# ── Codex session ───────────────────────────────────────────────────────────
if command -v codex >/dev/null 2>&1; then
  x_start=$(date +%s)
  CODEX_OUT="$(cd "$WORK/codex" && timeout 240 codex exec --skip-git-repo-check -s workspace-write -c model_reasoning_effort="medium" "$PROMPT" </dev/null 2>&1)"
  x_rc=$?; x_dur=$(( $(date +%s) - x_start ))
else
  CODEX_OUT="codex CLI not found on $NODE"; x_rc=127; x_dur=0
fi

# ── Distill ─────────────────────────────────────────────────────────────────
c_result="$(printf '%s\n' "$CLAUDE_OUT" | grep -m1 -i '^RESULT:' || echo 'RESULT: (no RESULT line emitted)')"
x_result="$(printf '%s\n' "$CODEX_OUT" | grep -m1 -i '^RESULT:' || echo 'RESULT: (no RESULT line emitted)')"
c_status=$([ "$c_rc" -eq 0 ] && echo ok || echo "fail(rc=$c_rc)")
x_status=$([ "$x_rc" -eq 0 ] && echo ok || echo "fail(rc=$x_rc)")
overall=$([ "$c_rc" -eq 0 ] && [ "$x_rc" -eq 0 ] && echo both_ok || { [ "$c_rc" -ne 0 ] && [ "$x_rc" -ne 0 ] && echo both_fail || echo partial; })

# ── Markdown report ─────────────────────────────────────────────────────────
{
  echo "# Dual math-session capability test — $STAMP ($NODE)"
  echo
  echo "| agent | status | duration | result |"
  echo "|-------|--------|----------|--------|"
  echo "| Claude | $c_status | ${c_dur}s | ${c_result#RESULT: } |"
  echo "| Codex  | $x_status | ${x_dur}s | ${x_result#RESULT: } |"
  echo
  echo "## Claude session output"; echo '```'; printf '%s\n' "$CLAUDE_OUT"; echo '```'
  echo "## Codex session output";  echo '```'; printf '%s\n' "$CODEX_OUT";  echo '```'
} > "$REPORT"

# ── Report to the cluster event log ─────────────────────────────────────────
detail="claude=$c_status/${c_dur}s codex=$x_status/${x_dur}s"
printf '{"ts":"%s","node":"%s","source":"cap-test","action":"dual-math","result":"%s","detail":"%s"}\n' \
  "$STAMP" "$NODE" "$overall" "$detail" >> "$EVENTS"

# ── Push the report so the whole cluster sees it (best-effort, selective) ────
cd "$REPO" || exit 0
git pull --ff-only origin main >/dev/null 2>&1 || true
git add logs/events.jsonl "logs/cap-tests/" >/dev/null 2>&1 || true
git -c user.name="monad-cap-test" -c user.email="cap-test@monad" \
    commit -q -m "cap-test: dual math session $STAMP on $NODE — $detail" >/dev/null 2>&1 || true
git push origin main >/dev/null 2>&1 || true

# ── Console summary (visible in `nomad alloc logs`) ──────────────────────────
echo "[dual-math-test] $NODE $STAMP -> $overall"
echo "[dual-math-test] Claude: $c_status ${c_dur}s | $c_result"
echo "[dual-math-test] Codex : $x_status ${x_dur}s | $x_result"
