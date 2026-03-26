job "math-quick-compute" {
  datacenters = ["dc1"]
  type        = "batch"

  periodic {
    crons            = ["30 1-23/2 * * *"]
    prohibit_overlap = true
    time_zone        = "America/Denver"
  }

  # Constrain to the node where Max account 2 is logged in
  constraint {
    attribute = "${meta.claude_account}"
    value     = "max-2"
  }

  group "compute" {
    count = 1

    task "session" {
      driver = "raw_exec"

      config {
        command = "/bin/bash"
        args    = ["-c", <<EOT
set -euo pipefail

WORK_DIR="/tmp/math-compute-$$"
trap "rm -rf $WORK_DIR" EXIT

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

MATH_REPO="${MATH_REPO_URL:-https://github.com/eliottcassidy2000/math.git}"
git clone --depth=20 "$MATH_REPO" math
cd math

echo "monad-compute" > .machine-id

# Claude Code uses the locally authenticated account — no API key needed
claude --print --dangerously-skip-permissions \
  "You are monad-compute, a computation agent in the Monad cluster.
   Your ONLY job is to run Python/C scripts and produce data. Be fast and focused.

   Startup (abbreviated — you are a compute node, not a theorist):
   1. Read 01-canon/MISTAKES.md (critical — avoid known bugs)
   2. Read 00-navigation/OPEN-QUESTIONS.md for computation needs
   3. git pull
   4. python3 agents/processor.py --check

   Then:
   1. Pick ONE computation task from OPEN-QUESTIONS.md or 05-knowledge/hypotheses/
   2. Find the relevant script in 04-computation/
   3. Run it with: ./run_and_save.sh SCRIPT.py 1800  (30 min timeout)
   4. If no existing script fits, write a NEW script and save it to 04-computation/
   5. Save ALL output to 05-knowledge/results/
   6. If the result confirms or refutes a hypothesis, update 05-knowledge/hypotheses/INDEX.md
   7. Commit and push

   IMPORTANT:
   - Check MISTAKES.md before running any script — some have known bugs
   - Always use ./run_and_save.sh, never run scripts directly
   - If a script takes >30 minutes, note it for the researcher to handle
   - No proof attempts, no paper writing — JUST COMPUTE"

EOT
        ]
      }

      env {
        MATH_REPO_URL    = "https://github.com/eliottcassidy2000/math.git"
        GIT_AUTHOR_NAME  = "monad-compute"
        GIT_AUTHOR_EMAIL = "monad@cluster.local"
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
