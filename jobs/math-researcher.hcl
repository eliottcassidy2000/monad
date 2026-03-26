job "math-researcher" {
  datacenters = ["dc1"]
  type        = "batch"

  # Run a research session every 6 hours
  periodic {
    crons            = ["0 */6 * * *"]
    prohibit_overlap = true
    time_zone        = "America/Denver"
  }

  group "researcher" {
    count = 1

    # Prefer Linux nodes with Docker for isolation, but allow any node
    task "claude-research-session" {
      driver = "raw_exec"

      config {
        command = "/bin/bash"
        args    = ["-c", <<EOT
set -euo pipefail

WORK_DIR="/tmp/math-research-$$"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# Clone the math repo (or the cluster's fork when available)
MATH_REPO="${MATH_REPO_URL:-https://github.com/eliottcassidy2000/math.git}"
git clone --depth=50 "$MATH_REPO" math
cd math

# Generate a session focus based on day-of-week rotation
DAY=$(date +%u)
case $DAY in
  1) FOCUS="Pick the highest-priority red open question from OPEN-QUESTIONS.md and make progress on it" ;;
  2) FOCUS="Run computation scripts in 04-computation/ to extend known sequences or verify conjectures" ;;
  3) FOCUS="Review hypotheses in 05-knowledge/hypotheses/ — try to prove or refute one" ;;
  4) FOCUS="Explore connections in TANGENTS.md — develop the most promising cross-domain link" ;;
  5) FOCUS="Engineering: improve a tool in 04-computation/ or build something from OPEN-QUESTIONS.md engineering tasks" ;;
  6) FOCUS="Write up a result from 05-knowledge/results/ as a clean proof or paper section" ;;
  7) FOCUS="Free exploration: read the CONCEPT-MAP.md and investigate whatever seems most promising" ;;
esac

# Run a Claude Code session with the research focus
claude --print --dangerously-skip-permissions \
  "You are a math research agent in the Monad cluster. Follow CLAUDE.md exactly.
   Your focus this session: $FOCUS

   After doing your work:
   1. Save all results to 05-knowledge/results/
   2. Update SESSION-LOG.md with what you did
   3. Commit and push your work
   4. Use agents/finish_session.py to close properly"

# Cleanup
rm -rf "$WORK_DIR"
EOT
        ]
      }

      env {
        ANTHROPIC_API_KEY = "${ANTHROPIC_API_KEY}"
        MATH_REPO_URL     = "https://github.com/eliottcassidy2000/math.git"
        GIT_AUTHOR_NAME   = "monad-researcher"
        GIT_AUTHOR_EMAIL  = "monad@cluster.local"
      }

      resources {
        cpu    = 500
        memory = 1024
      }

      # Research sessions can run up to 2 hours
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
