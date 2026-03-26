job "math-quick-compute" {
  datacenters = ["dc1"]
  type        = "batch"

  # Run computation jobs every 2 hours, offset from researcher
  periodic {
    crons            = ["30 1-23/2 * * *"]
    prohibit_overlap = true
    time_zone        = "America/Denver"
  }

  group "compute" {
    count = 1

    task "run-computation" {
      driver = "raw_exec"

      config {
        command = "/bin/bash"
        args    = ["-c", <<EOT
set -euo pipefail

WORK_DIR="/tmp/math-compute-$$"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

MATH_REPO="${MATH_REPO_URL:-https://github.com/eliottcassidy2000/math.git}"
git clone --depth=20 "$MATH_REPO" math
cd math

# Quick Claude session focused purely on computation
claude --print --dangerously-skip-permissions \
  "You are a computation agent in the Monad cluster.
   Your ONLY job is to run Python scripts from 04-computation/ and save results.

   1. Read 00-navigation/OPEN-QUESTIONS.md for computation needs
   2. Pick ONE script that can produce new data in under 30 minutes
   3. Run it with ./run_and_save.sh SCRIPT.py 1800
   4. Save output to 05-knowledge/results/
   5. If the result is interesting, note it in SESSION-LOG.md
   6. Commit and push

   Be fast and focused. No theorizing — just compute."

rm -rf "$WORK_DIR"
EOT
        ]
      }

      env {
        ANTHROPIC_API_KEY = "${ANTHROPIC_API_KEY}"
        MATH_REPO_URL     = "https://github.com/eliottcassidy2000/math.git"
        GIT_AUTHOR_NAME   = "monad-compute"
        GIT_AUTHOR_EMAIL  = "monad@cluster.local"
      }

      resources {
        cpu    = 2000
        memory = 2048
      }

      kill_timeout = "10s"
    }

    restart {
      attempts = 1
      interval = "30m"
      delay    = "5m"
      mode     = "fail"
    }
  }
}
