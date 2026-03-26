job "claude-monitor" {
  datacenters = ["dc1"]
  type        = "batch"

  periodic {
    crons            = ["*/10 * * * *"]
    prohibit_overlap = true
  }

  # Only run on nodes that have Claude Code installed
  constraint {
    attribute = "${meta.has_claude}"
    value     = "true"
  }

  group "monitor" {
    count = 1

    task "claude-check" {
      driver = "raw_exec"

      config {
        command = "/home/e/monad/scripts/claude-monitor.sh"
      }

      env {
        NOMAD_ADDR = "http://100.78.218.70:4646"
        HOME       = "/home/e"
        PATH       = "/home/e/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
      }

      resources {
        cpu    = 200
        memory = 256
      }

      # Give Claude time to think (2 min should be plenty for a status check)
      kill_timeout = "30s"
    }
  }
}
