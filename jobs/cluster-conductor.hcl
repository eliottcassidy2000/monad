# cluster-conductor — the singular, always-on Claude instance for the whole cluster.
#
# One brain, two front doors:
#   * Tailscale text gateway   — POST http://<V1410-1-tailnet-ip>:8200/ask
#   * Remote-control session   — appears in the Claude app (claude.ai/code) under the
#                                account; the owner attaches from desktop or phone.
#
# RE-HOMED to V1410-1 (the permanent, always-on leader) on 2026-06-03. Previously
# pinned to oraclebox1; when that node went down the conductor could not be placed
# anywhere and `nomad job restart` was a no-op, so the watcher self-heal loop could
# not recover it. The image is now published multi-arch (amd64+arm64), so it runs on
# V1410-1 (amd64) as well as oraclebox1 (arm64). Host paths are V1410-1's (/home/e,
# uid 1000) mapped to the container's /home/ubuntu (also uid 1000) so the mounted
# credentials stay writable and token refresh works.
job "cluster-conductor" {
  datacenters = ["dc1"]
  type        = "service"

  # Pin to V1410-1 — the always-on permanent leader that holds the Claude
  # credentials and a monad checkout. Removes the single point of failure on the
  # intermittent oraclebox1 cloud node.
  constraint {
    attribute = "${node.unique.name}"
    value     = "V1410-1"
  }

  group "conductor" {
    count = 1

    restart {
      attempts = 5
      interval = "10m"
      delay    = "20s"
      mode     = "delay"
    }

    # When the node briefly flaps, keep trying to place indefinitely.
    reschedule {
      delay          = "30s"
      delay_function = "exponential"
      max_delay      = "1h"
      unlimited      = true
    }

    network {
      mode = "host"
    }

    service {
      name     = "cluster-conductor"
      provider = "nomad"
      port     = "8200"

      check {
        type     = "http"
        protocol = "http"
        port     = "8200"
        path     = "/health"
        interval = "30s"
        timeout  = "5s"
      }
    }

    task "conductor" {
      driver = "docker"

      config {
        image        = "ghcr.io/eliott-monad/monad-conductor:latest"
        network_mode = "host"
        # GHCR pull auth — templated from the encrypted Nomad variable so the
        # package can stay private (no committed credentials).
        auth {
          username = "eliottcassidy2000"
          password = "${GHCR_TOKEN}"
        }
        # mounts: creds (rw for token refresh), repo, tailscale socket + host CLIs.
        # Host side is V1410-1's /home/e; container side stays /home/ubuntu.
        volumes = [
          "/home/e/.claude:/home/ubuntu/.claude",
          "/home/e/.claude.json:/home/ubuntu/.claude.json",
          "/home/e/monad:/work",
          "/var/run/tailscale:/var/run/tailscale",
          "/usr/bin/nomad:/host/bin/nomad:ro",
          "/usr/bin/tailscale:/host/bin/tailscale:ro",
        ]
      }

      # GitOps push token + GHCR pull token. Stored at nomad/jobs/cluster-conductor
      # so the task's default workload identity can read it with no extra ACL policy
      # (the idiomatic pattern other fleet jobs use, e.g. postgres-backup).
      template {
        data        = <<-EOH
          GH_TOKEN={{ with nomadVar "nomad/jobs/cluster-conductor" }}{{ .github_token }}{{ end }}
          GHCR_TOKEN={{ with nomadVar "nomad/jobs/cluster-conductor" }}{{ .ghcr_token }}{{ end }}
        EOH
        destination = "secrets/conductor.env"
        env         = true
      }

      env {
        NOMAD_ADDR        = "http://100.75.75.39:4646"
        CONDUCTOR_BIND    = "0.0.0.0"
        CONDUCTOR_WORKDIR = "/work"
        CONDUCTOR_PORT    = "8200"
        MONAD_REPO_DIR    = "/work"
        # Bind all host interfaces so Nomad's default-interface health check and
        # Tailscale callers both reach the same gateway.
        # ENABLE_REMOTE_CONTROL=1 keeps the app-facing session alive (default)
      }

      resources {
        cpu    = 300
        memory = 768
      }
    }
  }
}
