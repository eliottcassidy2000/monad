# dual-math-test — scheduled capability test.
#
# A Nomad PERIODIC batch that auto-executes every 12h: runs one autonomous math session with
# Claude and one with Codex, then reports to the cluster (logs/events.jsonl + logs/cap-tests/,
# committed and pushed). Proves the cluster can schedule and autonomously drive both agents.
#
# Runs on the server (V1410-1) where both the claude and codex CLIs are installed and logged in.

job "dual-math-test" {
  datacenters = ["dc1"]
  type        = "batch"

  periodic {
    crons            = ["0 */12 * * *"]
    prohibit_overlap = true
    time_zone        = "America/Denver"
  }

  constraint {
    attribute = "${meta.role}"
    value     = "server"
  }

  group "test" {
    count = 1

    task "run" {
      driver = "raw_exec"

      config {
        command = "/bin/bash"
        args    = ["-c", "exec ${MONAD_REPO_DIR}/scripts/dual-math-test.sh"]
      }

      env {
        MONAD_REPO_DIR = "/home/e/monad"
        HOME           = "/home/e"
        NOMAD_ADDR     = "http://100.75.75.39:4646"
      }

      # Run as the repo owner so auth (~/.claude, ~/.codex) and git work.
      user = "e"

      resources {
        cpu    = 1000
        memory = 2048
      }
    }

    restart {
      attempts = 0
      mode     = "fail"
    }
  }
}
