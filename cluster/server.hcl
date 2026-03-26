# Monad Cluster - Server Node Configuration Template
# Copy to /etc/nomad.d/nomad.hcl on the bootstrap server
#
# Variables to replace:
#   TAILSCALE_IP - this node's Tailscale IP
#   NODE_NAME    - hostname

log_level = "INFO"
data_dir  = "/opt/nomad/data"
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

server {
  enabled          = true
  bootstrap_expect = 1
}

client {
  enabled = true

  meta {
    role     = "server"
    location = "home"
  }

  # Adjust path to match where the monad repo lives on this server
  host_volume "monad-repo" {
    path      = "/home/bigo/Documents/monad"
    read_only = false
  }
}

plugin "docker" {
  config {
    allow_privileged = false
    volumes {
      enabled = true
    }
  }
}

telemetry {
  disable_hostname       = true
  prometheus_metrics     = true
  publish_allocation_metrics = true
  publish_node_metrics       = true
}
