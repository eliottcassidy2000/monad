#!/usr/bin/env bash
# key-ring.sh — API key rotation for the Monad cluster
#
# The cluster has 4 Anthropic accounts:
#   MAX_KEY_1, MAX_KEY_2, MAX_KEY_3  — high-rate-limit keys for research jobs
#   PRO_KEY                          — lower-cost key for node maintenance
#
# Keys are stored as Nomad variables at: nomad/jobs/key-ring
# This script selects the right key based on job type and rotation strategy.
#
# Usage:
#   eval $(key-ring.sh research)   # → exports ANTHROPIC_API_KEY for a research session
#   eval $(key-ring.sh compute)    # → exports ANTHROPIC_API_KEY for computation
#   eval $(key-ring.sh review)     # → exports ANTHROPIC_API_KEY for review
#   eval $(key-ring.sh doctor)     # → exports ANTHROPIC_API_KEY for node maintenance
#   eval $(key-ring.sh round-robin) # → exports ANTHROPIC_API_KEY, rotating across Max keys
#
# Rotation strategies:
#   DEDICATED — each job type gets a fixed key (avoids cross-job rate limit contention)
#   ROUND_ROBIN — rotate across Max keys by hour (spreads load, better for bursty usage)
#
# The default is DEDICATED. Set MONAD_KEY_STRATEGY=round-robin to change.

set -euo pipefail

NOMAD_ADDR="${NOMAD_ADDR:-http://100.78.218.70:4646}"
export NOMAD_ADDR

JOB_TYPE="${1:-round-robin}"
STRATEGY="${MONAD_KEY_STRATEGY:-dedicated}"

# ─── Fetch keys from Nomad variables ─────────────────────────────────────────
# Keys are stored at: nomad/jobs/key-ring
# Set with: nomad var put nomad/jobs/key-ring MAX_KEY_1=sk-ant-... MAX_KEY_2=... MAX_KEY_3=... PRO_KEY=...

get_key() {
    local key_name="$1"
    local val
    val=$(nomad var get -item="$key_name" nomad/jobs/key-ring 2>/dev/null || echo "")
    if [ -z "$val" ]; then
        # Fallback: check environment
        val="${!key_name:-}"
    fi
    if [ -z "$val" ]; then
        echo "# ERROR: $key_name not found in Nomad vars or environment" >&2
        echo "# Set it with: nomad var put nomad/jobs/key-ring $key_name=sk-ant-..." >&2
        return 1
    fi
    echo "$val"
}

# ─── Selection logic ─────────────────────────────────────────────────────────

select_key() {
    case "$JOB_TYPE" in
        doctor|maintenance|pro)
            # Always use Pro key for maintenance
            get_key "PRO_KEY"
            ;;
        research|researcher)
            if [ "$STRATEGY" = "round-robin" ]; then
                round_robin_select
            else
                get_key "MAX_KEY_1"
            fi
            ;;
        compute|computation|quick-compute)
            if [ "$STRATEGY" = "round-robin" ]; then
                round_robin_select
            else
                get_key "MAX_KEY_2"
            fi
            ;;
        review|reviewer)
            if [ "$STRATEGY" = "round-robin" ]; then
                round_robin_select
            else
                get_key "MAX_KEY_3"
            fi
            ;;
        round-robin)
            round_robin_select
            ;;
        *)
            echo "# Unknown job type: $JOB_TYPE" >&2
            echo "# Valid types: research, compute, review, doctor, round-robin" >&2
            return 1
            ;;
    esac
}

round_robin_select() {
    # Rotate across Max keys based on current hour
    local hour
    hour=$(date +%H)
    local idx=$(( hour % 3 ))
    case $idx in
        0) get_key "MAX_KEY_1" ;;
        1) get_key "MAX_KEY_2" ;;
        2) get_key "MAX_KEY_3" ;;
    esac
}

# ─── Output ──────────────────────────────────────────────────────────────────

KEY=$(select_key)
if [ $? -eq 0 ] && [ -n "$KEY" ]; then
    echo "export ANTHROPIC_API_KEY='$KEY'"
    echo "# key-ring: selected $JOB_TYPE key (strategy: $STRATEGY)" >&2
else
    exit 1
fi
