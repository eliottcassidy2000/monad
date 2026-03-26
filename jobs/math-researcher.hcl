job "math-researcher" {
  datacenters = ["dc1"]
  type        = "batch"

  periodic {
    crons            = ["0 */6 * * *"]
    prohibit_overlap = true
    time_zone        = "America/Denver"
  }

  # Constrain to the node where Max account 1 is logged in
  constraint {
    attribute = "${meta.claude_account}"
    value     = "max-1"
  }

  group "researcher" {
    count = 1

    task "session" {
      driver = "raw_exec"

      config {
        command = "/bin/bash"
        args    = ["-c", <<EOT
set -euo pipefail

WORK_DIR="/tmp/math-research-$$"
trap "rm -rf $WORK_DIR" EXIT

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# Clone the math repo fresh each session
MATH_REPO="${MATH_REPO_URL:-https://github.com/eliottcassidy2000/math.git}"
git clone --depth=100 "$MATH_REPO" math
cd math

# Register as a Monad cluster agent if not already registered
echo "monad-researcher" > .machine-id
if [ -f agents/processor.py ]; then
    python3 agents/processor.py --register 2>/dev/null || true
fi

# Day-of-week rotation: systematic coverage of the research frontier
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

# Claude Code uses the locally authenticated account — no API key needed
claude --print --dangerously-skip-permissions \
  "You are monad-researcher, a Claude research agent in the Monad compute cluster.
   This is an autonomous research session. Follow CLAUDE.md EXACTLY — the startup
   sequence is mandatory:

   1. Read .machine-id (you are: monad-researcher)
   2. Read warm-up files IN ORDER:
      - 01-canon/MISTAKES.md
      - 01-canon/definitions.md
      - 00-navigation/OPEN-QUESTIONS.md
      - 00-navigation/SESSION-LOG.md (last few entries)
      - 00-navigation/TANGENTS.md (scan briefly)
   3. git pull
   4. python3 agents/processor.py --check (read your messages)
   5. python3 inbox/processor.py (process human inbox if anything there)

   YOUR FOCUS THIS SESSION: $FOCUS

   As you work:
   - Save ALL computation outputs via ./run_and_save.sh SCRIPT.py
   - Log every hypothesis to 05-knowledge/hypotheses/INDEX.md
   - Add new tangents to 00-navigation/TANGENTS.md
   - Check 01-canon/MISTAKES.md before trusting any computation
   - Open court cases for disagreements, never silently override canon

   BEFORE ENDING:
   1. Use agents/finish_session.py to close your session properly
   2. Or manually: python3 agents/processor.py --send --to all --subject 'monad-researcher session report'
   3. Update 00-navigation/SESSION-LOG.md
   4. git add -A && git commit && git push"

EOT
        ]
      }

      env {
        MATH_REPO_URL    = "https://github.com/eliottcassidy2000/math.git"
        GIT_AUTHOR_NAME  = "monad-researcher"
        GIT_AUTHOR_EMAIL = "monad@cluster.local"
      }

      resources {
        cpu    = 500
        memory = 1024
      }

      kill_timeout = "10s"
    }

    restart {
      attempts = 1
      interval = "1h"
      delay    = "5m"
      mode     = "fail"
    }
  }
}
