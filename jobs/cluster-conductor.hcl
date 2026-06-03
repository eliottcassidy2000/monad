# cluster-conductor — always-on supervisory LLM for the fleet.
#
# Re-homed from oraclebox1 to V1410-1 (the permanent, always-on leader) on
# 2026-06-03. The original deployment was pinned to oraclebox1 with host paths
# under /home/ubuntu; when that cloud node went down the conductor could not be
# placed anywhere, and the watcher self-heal loop's `nomad job restart` was a
# no-op (no allocation existed to restart). Pinning to the always-on leader
# removes that single point of failure. Host paths are V1410-1's (/home/e),
# mapped to the container's expected /home/ubuntu locations.
job "cluster-conductor" {
  datacenters = ["dc1"]
  type        = "service"
  priority    = 50

  # Run on the permanent always-on leader so the conductor is never orphaned by
  # an intermittent node going down.
  constraint {
    attribute = "${node.unique.name}"
    value     = "V1410-1"
  }

  group "conductor" {
    count = 1

    constraint {
      attribute = "${attr.nomad.service_discovery}"
      value     = "true"
    }

    network {
      mode = "host"
    }

    restart {
      attempts = 5
      interval = "10m"
      delay    = "20s"
      mode     = "delay"
    }

    reschedule {
      delay          = "30s"
      delay_function = "exponential"
      max_delay      = "1h"
      unlimited      = true
    }

    ephemeral_disk {
      size = 300
    }

    service {
      name     = "cluster-conductor"
      port     = "8200"
      provider = "nomad"

      check {
        type     = "http"
        path     = "/health"
        port     = "8200"
        interval = "30s"
        timeout  = "5s"
      }
    }

    task "conductor" {
      driver = "docker"

      config {
        image        = "ghcr.io/eliott-monad/monad-conductor:latest"
        network_mode = "host"

        auth {
          username = "eliottcassidy2000"
          password = "${GHCR_TOKEN}"
        }

        # host:container — host paths are V1410-1's; container paths are what the
        # conductor image expects (it runs as the `ubuntu` user internally).
        volumes = [
          "/home/e/.claude:/home/ubuntu/.claude",
          "/home/e/.claude.json:/home/ubuntu/.claude.json",
          "/home/e/monad:/work",
          "/var/run/tailscale:/var/run/tailscale",
          "/usr/bin/nomad:/host/bin/nomad:ro",
          "/usr/bin/tailscale:/host/bin/tailscale:ro",
        ]
      }

      env {
        CONDUCTOR_BIND    = "0.0.0.0"
        CONDUCTOR_PORT    = "8200"
        CONDUCTOR_WORKDIR = "/work"
        MONAD_REPO_DIR    = "/work"
        # Point at this node's local Nomad (host networking).
        NOMAD_ADDR = "http://100.75.75.39:4646"
      }

      template {
        destination = "secrets/conductor.env"
        env         = true
        change_mode = "restart"
        data        = <<-EOH
        GH_TOKEN={{ with nomadVar "nomad/jobs/cluster-conductor" }}{{ .github_token }}{{ end }}
        GHCR_TOKEN={{ with nomadVar "nomad/jobs/cluster-conductor" }}{{ .ghcr_token }}{{ end }}
        EOH
      }

      resources {
        cpu    = 300
        memory = 768
      }
    }
  }
}
