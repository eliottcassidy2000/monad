job "math-quick-compute" {
  datacenters = ["dc1"]
  type        = "batch"

  periodic {
    crons            = ["30 1-23/2 * * *"]
    prohibit_overlap = true
    time_zone        = "America/Denver"
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
MONAD_DIR="${MONAD_REPO_DIR:-/home/bigo/Documents/monad}"
trap "rm -rf $WORK_DIR" EXIT

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# Select API key via key-ring (dedicated strategy: uses MAX_KEY_2)
if [ -f "$MONAD_DIR/scripts/key-ring.sh" ]; then
    eval $("$MONAD_DIR/scripts/key-ring.sh" compute 2>/dev/null) || true
fi
export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
if [ -z "$ANTHROPIC_API_KEY" ]; then
    echo "ERROR: No API key available"
    exit 1
fi

MATH_REPO="${MATH_REPO_URL:-https://github.com/eliottcassidy2000/math.git}"
git clone --depth=20 "$MATH_REPO" math
cd math

echo "monad-compute" > .machine-id

# Focused computation session — no theorizing, just crunch numbers
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
        MONAD_REPO_DIR = "/home/bigo/Documents/monad"
        MATH_REPO_URL  = "https://github.com/eliottcassidy2000/math.git"
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
