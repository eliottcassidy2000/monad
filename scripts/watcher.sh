#!/usr/bin/env bash
# watcher.sh <id> — one of THREE ever-present Codex watcher instances forming a quorum supervisor.
#
# Each watcher: heartbeats; leader-elects with its 2 peers; restarts any dead PEER watcher
# (mutual supervision); and runs a Codex pass (gpt-5.1, low effort) that — as leader — restarts
# any down cluster SERVICE. Run one per id (1,2,3) via systemd unit monad-watcher@<id>.service.
# Base supervision (the process itself) is systemd Restart=always; the watchers additionally
# restart each other if a heartbeat goes stale (covers a hung-but-alive process).
set -uo pipefail

ID="${1:?usage: watcher.sh <1|2|3>}"
REPO="${MONAD_REPO_DIR:-/home/e/monad}"
HB="${WATCHER_HB_DIR:-/home/e/.monad/watchers}"; mkdir -p "$HB"
EVENTS="$REPO/logs/events.jsonl"
PROMPT_FILE="$REPO/scripts/prompts/watcher.md"
INTERVAL="${WATCHER_INTERVAL:-120}"; STALE=$(( INTERVAL * 4 ))
GRACE="${WATCHER_GRACE:-$STALE}"   # at startup, give peers time to establish heartbeats first
IDS="1 2 3"
MODEL="${WATCHER_MODEL:-gpt-5.4-mini}"     # older + cheaper than the default gpt-5.5 (mini)
EFFORT="${WATCHER_EFFORT:-low}"
export HOME="${HOME:-/home/e}"
export PATH="$PATH:/usr/bin:/usr/local/bin:/home/e/bin"
export NOMAD_ADDR="${NOMAD_ADDR:-http://100.75.75.39:4646}"

now(){ date +%s; }
beat(){ now > "$HB/watcher-$ID"; }
fresh(){ local t; t=$(cat "$HB/watcher-$1" 2>/dev/null || echo 0); [ $(( $(now) - t )) -lt "$STALE" ]; }
ev(){ printf '{"ts":"%s","node":"%s","source":"watcher-%s","action":"%s","result":"%s","detail":"%s"}\n' \
  "$(date +%Y%m%dT%H%M%S)" "$(hostname)" "$ID" "$1" "$2" "${3//\"/\'}" >> "$EVENTS" 2>/dev/null || true; }

beat; START=$(now); ev quorum join "watcher $ID online (model=$MODEL effort=$EFFORT)"

while true; do
  beat
  ALIVE=""; for p in $IDS; do fresh "$p" && ALIVE="$ALIVE $p"; done; ALIVE="${ALIVE# }"
  NA=$(echo "$ALIVE" | wc -w); LEADER=$(echo "$ALIVE" | tr ' ' '\n' | sort -n | head -1)
  QUORUM=$([ "${NA:-0}" -ge 2 ] && echo yes || echo no)

  # ── mutual supervision: restart any peer that isn't heartbeating ───────────
  # systemd (Restart=always) handles a crashed peer in seconds; this catches a HUNG or
  # externally-stopped peer. Skip during the startup grace so a just-booting peer that
  # hasn't written its first heartbeat yet isn't needlessly bounced.
  if [ $(( $(now) - START )) -ge "$GRACE" ]; then
    for p in $IDS; do
      [ "$p" = "$ID" ] && continue
      if ! fresh "$p"; then
        sudo -n systemctl restart "monad-watcher@$p.service" 2>/dev/null \
          && ev peer-restart ok "restarted non-heartbeating watcher $p"
      fi
    done
  fi

  # ── Codex health pass (the watcher IS Codex) ───────────────────────────────
  ROLE=$([ "$ID" = "${LEADER:-$ID}" ] && echo leader || echo follower)
  SUM=""
  if [ -f "$PROMPT_FILE" ]; then
    P="$(sed "s/{{ID}}/$ID/g; s/{{ROLE}}/$ROLE/g; s/{{LEADER}}/${LEADER:-?}/g; s/{{ALIVE}}/$ALIVE/g; s/{{QUORUM}}/$QUORUM/g" "$PROMPT_FILE")"
    beat  # keep heartbeat fresh across the (slower) codex call
    OUT="$(cd /tmp && timeout 150 codex exec --skip-git-repo-check -s danger-full-access \
            -m "$MODEL" -c model_reasoning_effort="$EFFORT" "$P" </dev/null 2>&1)" || true
    printf '%s\n' "$OUT" > "$HB/watcher-$ID.lastrun" 2>/dev/null || true
    # take the agent's real WATCHER line (last one), not codex's echoed prompt placeholder
    SUM="$(printf '%s\n' "$OUT" | grep -i '^WATCHER:' | grep -vF 'terse sentence' | tail -1 | cut -c1-280)"
  fi

  beat
  ev cycle "$([ "$QUORUM" = yes ] && echo ok || echo degraded)" \
     "role=$ROLE leader=${LEADER:-?} alive=[$ALIVE] ${SUM:-no-summary}"
  sleep "$INTERVAL"
done
