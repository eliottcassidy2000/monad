# net-diag — cluster networking investigation (see NETWORKING.md).
#
# A `system` job: Nomad runs ONE allocation on EVERY eligible node, so each machine probes the
# network from its own vantage point and reports to logs/metrics/net-diag-<host>.json +
# logs/events.jsonl. The payoff: when a node is wired through V1410 (gateway 192.168.51.1),
# its large-TCP probe DEFINITIVELY tests the broken router forward-path from a real client —
# something the router can only approximate locally. Each probe loops every 10 minutes.

job "net-diag" {
  datacenters = ["dc1"]
  type        = "system"

  group "diag" {
    task "probe" {
      driver = "raw_exec"

      config {
        command = "/bin/bash"
        args    = ["-c", "exec ${MONAD_REPO_DIR}/scripts/net-diag.sh --loop 600"]
      }

      env {
        MONAD_REPO_DIR = "/home/e/monad"
      }

      resources {
        cpu    = 50
        memory = 64
      }
    }
  }
}
