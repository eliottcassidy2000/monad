job "service-patcher" {
  datacenters = ["dc1"]
  type        = "batch"

  # Run daily at 4 AM
  periodic {
    crons            = ["0 4 * * *"]
    prohibit_overlap = true
    time_zone        = "America/Chicago"
  }

  constraint {
    attribute = "${meta.role}"
    value     = "server"
  }

  group "patcher" {
    count = 1

    volume "monad-repo" {
      type      = "host"
      source    = "monad-repo"
      read_only = false
    }

    task "patch" {
      driver = "raw_exec"

      config {
        command = "/bin/bash"
        args    = ["/home/bigo/Documents/monad/scripts/service-patcher.sh"]
      }

      env {
        NOMAD_ADDR = "http://100.78.218.70:4646"
        VAULT_ADDR = "http://100.78.218.70:8200"
      }

      resources {
        cpu    = 500
        memory = 512
      }
    }
  }
}
