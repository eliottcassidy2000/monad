job "math-reviewer" {
  datacenters = ["dc1"]
  type        = "batch"

  periodic {
    crons            = ["0 3 * * *"]
    prohibit_overlap = true
    time_zone        = "America/Denver"
  }

  # Constrain to the node where Max account 3 is logged in
  constraint {
    attribute = "${meta.claude_account}"
    value     = "max-3"
  }

  group "reviewer" {
    count = 1

    task "session" {
      driver = "raw_exec"

      config {
        command = "/bin/bash"
        args    = ["-c", <<EOT
set -euo pipefail

WORK_DIR="/tmp/math-review-$$"
trap "rm -rf $WORK_DIR" EXIT

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

MATH_REPO="${MATH_REPO_URL:-https://github.com/eliottcassidy2000/math.git}"
git clone "$MATH_REPO" math
cd math

echo "monad-reviewer" > .machine-id

# Claude Code uses the locally authenticated account — no API key needed
claude --print --dangerously-skip-permissions \
  "You are monad-reviewer, the quality control agent in the Monad cluster.
   You are the skeptic. Your job is to VERIFY, CHALLENGE, and SYNTHESIZE.

   Full startup sequence (you need the complete picture):
   1. Read 01-canon/MISTAKES.md — you are the guardian of this file
   2. Read 01-canon/definitions.md — ensure all usage is consistent
   3. Read 00-navigation/OPEN-QUESTIONS.md
   4. Read 00-navigation/SESSION-LOG.md — FULL file, not just recent entries
   5. Read 00-navigation/TANGENTS.md
   6. git log --oneline -20 (see what happened in the last day)
   7. python3 agents/processor.py --check

   YOUR TASKS:
   1. VERIFY: For each new result in 05-knowledge/results/ from the last 24 hours:
      - Re-derive the key step from definitions
      - Check against MISTAKES.md for known pitfalls
      - If something looks wrong, OPEN A COURT CASE in 02-court/active/
      - If correct, note verification in the result file
   2. SYNTHESIZE: Write a daily digest entry in SESSION-LOG.md summarizing:
      - What was computed, proved, or discovered
      - What failed or was refuted
      - Key open threads for tomorrow
   3. REPRIORITIZE: Update OPEN-QUESTIONS.md based on new results
   4. COORDINATE: Send messages via agents/processor.py to guide the other agents
   5. CLEAN: Check for stale hypotheses, duplicate results, inconsistencies

   Use agents/finish_session.py to close.
   Be rigorous. The court system exists for a reason. Use it."

EOT
        ]
      }

      env {
        MATH_REPO_URL    = "https://github.com/eliottcassidy2000/math.git"
        GIT_AUTHOR_NAME  = "monad-reviewer"
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
      delay    = "10m"
      mode     = "fail"
    }
  }
}
