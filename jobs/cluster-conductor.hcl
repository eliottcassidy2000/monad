# cluster-conductor — always-on supervisory LLM for the fleet.
#
# IMPORTANT — single point of failure by image architecture:
#   The image ghcr.io/eliott-monad/monad-conductor:latest is built ARM64-only
#   (oraclebox1 is an Oracle Cloud Ampere / arm64 box). The only up arm64 node
#   besides oraclebox1 is eliotts-mac-mini, which is macOS and cannot run a
#   Linux container. Every other up node (V1410-1, claudebox, death-star,
#   bigo-server, windesk) is amd64 and gives `exec format error` on this image.
#   => Today this job can ONLY run on oraclebox1. While oraclebox1 is down it
#      cannot be placed anywhere; `nomad job restart` is a no-op (no alloc) and
#      the watcher self-heal loop cannot recover it.
#
# To make the conductor portable (run on the always-on leader V1410-1), the
# image must be published multi-arch (amd64+arm64) — see BACKLOG / monad idea.
# Until then this stays pinned to oraclebox1, and `reschedule { unlimited }`
# means the conductor auto-recovers the instant oraclebox1 rejoins the cluster.
job "cluster-conductor" {
  datacenters = ["dc1"]
  type        = "service"
  priority    = 50

  constraint {
    attribute = "${node.unique.name}"
    value     = "oraclebox1"
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

    # Unlimited reschedule => when oraclebox1 returns, the conductor is placed
    # automatically without any operator action.
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

        # Host paths are oraclebox1's (user `ubuntu`).
        volumes = [
          "/home/ubuntu/.claude:/home/ubuntu/.claude",
          "/home/ubuntu/.claude.json:/home/ubuntu/.claude.json",
          "/home/ubuntu/monad:/work",
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
        NOMAD_ADDR        = "http://100.125.210.126:4646"
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
