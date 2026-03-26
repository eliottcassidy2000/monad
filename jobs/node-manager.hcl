job "node-manager" {
  datacenters = ["dc1"]
  type        = "system"

  # Full sysadmin on nodes with raw_exec (host-level access)
  constraint {
    attribute = "${attr.kernel.name}"
    value     = "linux"
  }

  constraint {
    attribute = "${attr.driver.raw_exec}"
    value     = "1"
  }

  group "manager" {
    task "sysadmin" {
      driver = "raw_exec"

      config {
        command = "/bin/bash"
        args    = ["local/manage.sh"]
      }

      template {
        destination = "local/manage.sh"
        perms       = "755"
        data        = <<-SCRIPT
          #!/bin/bash
          set -euo pipefail

          HOSTNAME=$(hostname)
          log() { echo "[node-manager $HOSTNAME $(date '+%Y-%m-%d %H:%M:%S')] $*"; }

          manage_cycle() {
            log "=== Starting management cycle ==="

            # --- 1. Package updates ---
            log "Checking for package updates..."
            DEBIAN_FRONTEND=noninteractive apt-get update -qq 2>&1 || log "WARN: apt update failed"

            UPGRADABLE=$(apt list --upgradable 2>/dev/null | grep -c upgradable || echo "0")
            log "Upgradable packages: $UPGRADABLE"

            if [ "$UPGRADABLE" -gt 0 ]; then
              log "Applying upgrades..."
              DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq \
                -o Dpkg::Options::='--force-confdef' \
                -o Dpkg::Options::='--force-confold' 2>&1 || log "WARN: apt upgrade had issues"
            fi

            # --- 2. Service health checks ---
            log "Checking critical services..."
            for svc in nomad docker tailscaled; do
              if ! systemctl list-unit-files "$svc.service" &>/dev/null; then
                continue
              fi
              STATUS=$(systemctl is-active $svc 2>/dev/null || echo "inactive")
              if [ "$STATUS" = "active" ]; then
                log "  OK $svc: active"
              else
                log "  WARN $svc: $STATUS -- restarting"
                systemctl restart $svc 2>&1 || log "  ERROR: failed to restart $svc"
              fi
            done

            # --- 3. Disk space ---
            log "Disk usage:"
            df -h / /srv/samba/public 2>/dev/null || df -h /
            ROOT_PCT=$(df / --output=pcent | tail -1 | tr -d ' %')
            log "  Root: ${ROOT_PCT}% used"

            if [ "$ROOT_PCT" -gt 85 ]; then
              log "WARNING: Root disk > 85% -- cleaning up"
              apt-get autoremove -y -qq && apt-get clean 2>&1 || true
              journalctl --vacuum-time=3d 2>&1 || true
              if command -v docker &>/dev/null; then
                docker system prune -f --filter 'until=72h' 2>&1 || true
              fi
            fi

            # --- 4. Docker maintenance ---
            if command -v docker &>/dev/null && systemctl is-active docker &>/dev/null; then
              log "Docker cleanup..."
              docker image prune -f --filter 'until=168h' 2>&1 || true
              docker system df 2>/dev/null || true
            fi

            # --- 5. System health ---
            log "System health:"
            log "  Load: $(cat /proc/loadavg)"
            log "  Memory: $(free -h | awk '/Mem/{print "Used: "$3"/"$2" (Available: "$7")"}')"
            log "  Uptime: $(uptime -p)"

            # --- 6. Zombie check ---
            ZOMBIES=$(ps -eo stat | grep -c '^Z' || echo "0")
            [ "$ZOMBIES" -gt 0 ] && log "WARNING: $ZOMBIES zombie processes"

            # --- 7. Time sync ---
            if command -v timedatectl &>/dev/null; then
              TIME_OK=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo "unknown")
              if [ "$TIME_OK" = "yes" ]; then
                log "  OK NTP synced"
              else
                log "  WARN NTP not synced -- enabling"
                timedatectl set-ntp true 2>&1 || true
              fi
            fi

            # --- 8. Nomad + Tailscale self-check ---
            log "  Nomad: $(nomad version 2>/dev/null | head -1 || echo 'unknown')"
            if command -v tailscale &>/dev/null; then
              log "  Tailscale: $(tailscale ip -4 2>/dev/null || echo 'unknown')"
            fi

            # --- 9. Log rotation check ---
            LARGE_LOGS=$(find /var/log -name "*.log" -size +100M 2>/dev/null | head -5)
            if [ -n "$LARGE_LOGS" ]; then
              log "WARNING: Large log files found:"
              echo "$LARGE_LOGS" | while read -r f; do
                log "  $(ls -lh "$f" 2>/dev/null)"
              done
            fi

            log "=== Management cycle complete ==="
          }

          log "Node manager starting (10-minute cycle) [raw_exec / full admin]"

          while true; do
            manage_cycle || log "ERROR: Management cycle failed"
            log "Sleeping 600s..."
            sleep 600
          done
        SCRIPT
      }

      resources {
        cpu    = 100
        memory = 256
      }
    }
  }
}
