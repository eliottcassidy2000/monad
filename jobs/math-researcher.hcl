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
        args    = ["-c", "exec ${MONAD_REPO_DIR:-/home/${USER:-bigo}/monad}/scripts/math-session.sh researcher 100"]
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
