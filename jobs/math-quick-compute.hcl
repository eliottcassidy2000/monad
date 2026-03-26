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
        args    = ["-c", "exec ${MONAD_REPO_DIR:-/home/${USER:-bigo}/monad}/scripts/math-session.sh compute 20"]
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
