# Monad Cluster - Windows Client Node Configuration Template
# For Windows nodes joining via Tailscale
#
# Variables to replace:
#   TAILSCALE_IP - this node's Tailscale IP
#   NODE_NAME    - hostname
#   SERVER_IP    - bootstrap server's Tailscale IP (100.78.218.70)

log_level = "INFO"
data_dir  = "C:\\nomad\\data"
name      = "NODE_NAME"

bind_addr = "TAILSCALE_IP"

advertise {
  http = "TAILSCALE_IP"
  rpc  = "TAILSCALE_IP"
  serf = "TAILSCALE_IP"
}

ports {
  http = 4646
  rpc  = 4647
  serf = 4648
}

client {
  enabled = true

  servers = ["SERVER_IP:4647"]

  meta {
    role         = "worker"
    platform     = "windows"
    location     = "unknown"
    capabilities = "claude-code,raw-exec"
  }
}

plugin "raw_exec" {
  config {
    enabled = true
  }
}

telemetry {
  disable_hostname           = true
  prometheus_metrics         = true
  publish_allocation_metrics = true
  publish_node_metrics       = true
}
