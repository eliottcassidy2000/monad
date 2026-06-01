job "math-formalizer" {
  datacenters = ["dc1"]
  type        = "batch"

  periodic {
    crons            = ["0 */4 * * *"]
    prohibit_overlap = true
    time_zone        = "America/Denver"
  }

  # Formalization is light/short — run it on the Pro account node so it never competes
  # with the Max research/compute/reviewer agents for quota.
  constraint {
    attribute = "${meta.claude_account}"
    value     = "pro"
  }

  group "formalizer" {
    count = 1

    task "session" {
      driver = "raw_exec"

      config {
        command = "/bin/bash"
        args    = ["-c", "exec ${MONAD_REPO_DIR:-/home/${USER:-bigo}/monad}/scripts/formalizer-session.sh 0"]
      }

      env {
        LEAN_REPO_URL    = "https://github.com/claude-monad/math-lean.git"
        MATH_REPO_URL    = "https://github.com/eliottcassidy2000/math.git"
        GIT_AUTHOR_NAME  = "monad-formalizer"
        GIT_AUTHOR_EMAIL = "monad@cluster.local"
      }

      resources {
        cpu    = 1000
        memory = 2048
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
