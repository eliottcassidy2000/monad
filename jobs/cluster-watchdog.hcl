job "cluster-watchdog" {
  datacenters = ["dc1"]
  type        = "batch"

  periodic {
    crons            = ["*/15 * * * *"]  # Every 15 minutes
    prohibit_overlap = true
    time_zone        = "America/Denver"
  }

  # Must run on the server (needs Nomad API access and monad-repo volume)
  constraint {
    attribute = "${meta.role}"
    value     = "server"
  }

  group "watchdog" {
    count = 1

    volume "monad-repo" {
      type      = "host"
      source    = "monad-repo"
      read_only = false
    }

    task "check" {
      driver = "raw_exec"

      config {
        command = "/bin/bash"
        args    = ["-c", "exec ${MONAD_REPO_DIR:-/home/bigo/Documents/monad}/scripts/cluster-watchdog.sh"]
      }

      volume_mount {
        volume      = "monad-repo"
        destination = "/monad"
        read_only   = false
      }

      env {
        MONAD_REPO_DIR = "/monad"
      }

      resources {
        cpu    = 200
        memory = 256
      }
    }

    restart {
      attempts = 1
      interval = "15m"
      delay    = "1m"
      mode     = "fail"
    }
  }
}
