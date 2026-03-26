job "monad-sync" {
  datacenters = ["dc1"]
  type        = "batch"

  periodic {
    crons            = ["*/5 * * * *"]
    prohibit_overlap = true
  }

  constraint {
    attribute = "${meta.role}"
    value     = "server"
  }

  group "sync" {
    count = 1

    volume "monad-repo" {
      type      = "host"
      source    = "monad-repo"
      read_only = false
    }

    task "git-sync" {
      driver = "raw_exec"

      config {
        command = "/home/bigo/Documents/monad/scripts/sync.sh"
      }

      env {
        NOMAD_ADDR     = "http://100.78.218.70:4646"
        MONAD_REPO_DIR = "/home/bigo/Documents/monad"
      }

      resources {
        cpu    = 100
        memory = 128
      }
    }
  }
}
