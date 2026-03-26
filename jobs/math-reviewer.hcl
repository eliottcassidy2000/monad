job "math-reviewer" {
  datacenters = ["dc1"]
  type        = "batch"

  # Run once daily at 3 AM — reviews the day's work
  periodic {
    crons            = ["0 3 * * *"]
    prohibit_overlap = true
    time_zone        = "America/Denver"
  }

  group "reviewer" {
    count = 1

    task "daily-review" {
      driver = "raw_exec"

      config {
        command = "/bin/bash"
        args    = ["-c", <<EOT
set -euo pipefail

WORK_DIR="/tmp/math-review-$$"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

MATH_REPO="${MATH_REPO_URL:-https://github.com/eliottcassidy2000/math.git}"
git clone "$MATH_REPO" math
cd math

# Review session — quality control and synthesis
claude --print --dangerously-skip-permissions \
  "You are a review agent in the Monad cluster. Your job is quality control.

   1. Read the last 24 hours of SESSION-LOG.md entries
   2. Check git log for today's commits
   3. For each new result in 05-knowledge/results/:
      - Verify the reasoning is sound
      - Check against 01-canon/MISTAKES.md for known pitfalls
      - If something looks wrong, open a court case in 02-court/active/
   4. Update OPEN-QUESTIONS.md: mark progress, reprioritize based on new results
   5. Write a brief daily digest and add it to SESSION-LOG.md
   6. Send a summary message via agents/processor.py to all registered agents
   7. Commit and push

   Be rigorous. Challenge claims. The court system exists for a reason."

rm -rf "$WORK_DIR"
EOT
        ]
      }

      env {
        ANTHROPIC_API_KEY = "${ANTHROPIC_API_KEY}"
        MATH_REPO_URL     = "https://github.com/eliottcassidy2000/math.git"
        GIT_AUTHOR_NAME   = "monad-reviewer"
        GIT_AUTHOR_EMAIL  = "monad@cluster.local"
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
