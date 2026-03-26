job "node-monitor" {
  datacenters = ["dc1"]
  type        = "system"

  # Lightweight monitoring for exec-only nodes (no raw_exec)
  constraint {
    attribute = "${attr.kernel.name}"
    value     = "linux"
  }

  constraint {
    attribute = "${attr.driver.exec}"
    value     = "1"
  }

  # Skip nodes that already run the full node-manager via raw_exec
  constraint {
    attribute = "${attr.driver.raw_exec}"
    operator  = "!="
    value     = "1"
  }

  group "monitor" {
    task "health-check" {
      driver = "exec"

      config {
        command = "/bin/bash"
        args    = ["local/monitor.sh"]
      }

      template {
        destination = "local/monitor.sh"
        perms       = "755"
        data        = <<-SCRIPT
          #!/bin/bash
          set -euo pipefail

          HOSTNAME=$(hostname)
          log() { echo "[node-monitor $HOSTNAME $(date '+%Y-%m-%d %H:%M:%S')] $*"; }

          monitor_cycle() {
            log "=== Health check ==="

            # System metrics
            log "  Load: $(cat /proc/loadavg)"
            log "  Memory: $(free -h 2>/dev/null | awk '/Mem/{print "Used: "$3"/"$2}' || echo 'N/A')"
            log "  Uptime: $(uptime -p 2>/dev/null || echo 'N/A')"

            # Disk
            df -h / 2>/dev/null | tail -1 | while IFS= read -r line; do
              log "  Disk: $line"
            done

            # Nomad
            NOMAD_VER=$(nomad version 2>/dev/null | head -1 || echo "unknown")
            log "  Nomad: $NOMAD_VER"

            # Process count
            PROCS=$(cat /proc/loadavg | awk -F'/' '{print $2}' | awk '{print $1}')
            log "  Processes: $PROCS"

            log "=== Health check complete ==="
          }

          log "Node monitor starting (10-minute cycle) [exec / read-only]"

          while true; do
            monitor_cycle || log "ERROR: Monitor cycle failed"
            sleep 600
          done
        SCRIPT
      }

      resources {
        cpu    = 50
        memory = 64
      }
    }
  }
}
