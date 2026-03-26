job "nfs-storage" {
  datacenters = ["dc1"]
  type        = "service"

  constraint {
    attribute = "${meta.role}"
    value     = "storage"
  }

  constraint {
    attribute = "${attr.driver.raw_exec}"
    value     = "1"
  }

  group "nfs" {
    count = 1

    network {
      port "nfs" {
        static = 2049
      }
    }

    # Manage the native NFS server on death-star
    task "nfs-watchdog" {
      driver = "raw_exec"

      config {
        command = "/bin/bash"
        args    = ["local/watchdog.sh"]
      }

      template {
        destination = "local/watchdog.sh"
        perms       = "755"
        data        = <<-SCRIPT
          #!/bin/bash
          set -euo pipefail

          log() { echo "[nfs-storage $(date '+%H:%M:%S')] $*"; }

          # Ensure exports are correct
          EXPECTED='/srv/samba/public 100.64.0.0/10(rw,sync,no_subtree_check,no_root_squash,fsid=0)'
          if ! grep -q '/srv/samba/public.*100.64.0.0/10' /etc/exports; then
            log "Updating /etc/exports..."
            echo "$EXPECTED" >> /etc/exports
            exportfs -ra
          fi

          # Ensure NFS server is running
          if ! systemctl is-active nfs-kernel-server &>/dev/null; then
            log "Starting NFS server..."
            systemctl start nfs-kernel-server
          fi

          log "NFS server active, monitoring..."
          exportfs -v

          # Watchdog loop - keep NFS healthy
          while true; do
            if ! systemctl is-active nfs-kernel-server &>/dev/null; then
              log "WARN: NFS server down, restarting..."
              systemctl restart nfs-kernel-server
            fi

            # Verify exports are still active
            ACTIVE_EXPORTS=$(exportfs -v 2>/dev/null | grep -c '/srv/samba/public' || echo "0")
            if [ "$ACTIVE_EXPORTS" -eq 0 ]; then
              log "WARN: No active exports, re-exporting..."
              exportfs -ra
            fi

            sleep 60
          done
        SCRIPT
      }

      resources {
        cpu    = 50
        memory = 64
      }

      service {
        name     = "nfs-storage"
        port     = "nfs"
        provider = "nomad"

        check {
          type     = "tcp"
          port     = "nfs"
          interval = "30s"
          timeout  = "5s"
        }
      }
    }
  }
}
