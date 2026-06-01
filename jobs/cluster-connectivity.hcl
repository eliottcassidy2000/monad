# cluster-connectivity — the shared-goal metric.
#
# Samples full-cluster connectivity (tailnet online AND nomad-ready, per roster node) every
# 5 minutes, appends to logs/metrics/connectivity.csv, computes rolling uptime, and emits a
# cluster event. This is how "full cluster connectivity and uptime" is MEASURED IN NOMAD:
# a Nomad-scheduled periodic batch whose score (connected/expected) every node can watch and
# drive toward 100%. See MISSION.md.
#
# Self-contained: raw_exec as user "e" reading the repo directly (no host volume needed), so
# it places cleanly on the always-on server.

job "cluster-connectivity" {
  datacenters = ["dc1"]
  type        = "batch"

  periodic {
    crons            = ["*/5 * * * *"]
    prohibit_overlap = true
    time_zone        = "America/Denver"
  }

  # Runs on the permanent server (V1410-1) — it always has the Nomad API and the repo.
  constraint {
    attribute = "${meta.role}"
    value     = "server"
  }

  group "probe" {
    count = 1

    task "measure" {
      driver = "raw_exec"

      config {
        command = "/bin/bash"
        args    = ["-c", "exec ${MONAD_REPO_DIR}/scripts/connectivity-probe.sh"]
      }

      env {
        MONAD_REPO_DIR = "/home/e/monad"
        NOMAD_ADDR     = "http://100.75.75.39:4646"
      }

      # Write metrics/events as the repo owner so git stays clean.
      user = "e"

      resources {
        cpu    = 100
        memory = 128
      }
    }

    restart {
      attempts = 1
      interval = "5m"
      delay    = "30s"
      mode     = "fail"
    }
  }
}
