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

    # Manage the native NFS server on the storage node
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

          # Config — override via Nomad meta or env
          EXPORT_PATH="${NFS_EXPORT_PATH:-/srv/samba/public}"
          TAILSCALE_CIDR="${NFS_TAILSCALE_CIDR:-100.64.0.0/10}"

          log() { echo "[nfs-storage $(date '+%H:%M:%S')] $*"; }

          # Idempotent exports setup — only add if not already present
          EXPECTED="$EXPORT_PATH $TAILSCALE_CIDR(rw,sync,no_subtree_check,no_root_squash,fsid=0)"
          if ! grep -qF "$EXPORT_PATH" /etc/exports 2>/dev/null; then
            log "Adding export: $EXPORT_PATH"
            echo "$EXPECTED" >> /etc/exports
            exportfs -ra
          elif ! grep -q "$TAILSCALE_CIDR" /etc/exports 2>/dev/null; then
            # Path exists but wrong network — update in place
            log "Updating export network for $EXPORT_PATH"
            sed -i "\|^${EXPORT_PATH}|c\\${EXPECTED}" /etc/exports
            exportfs -ra
          else
            log "Exports already correct"
          fi

          # Ensure NFS server is running
          if ! systemctl is-active nfs-kernel-server &>/dev/null; then
            log "Starting NFS server..."
            systemctl start nfs-kernel-server
          fi

          log "NFS server active, monitoring..."
          exportfs -v

          # Watchdog loop — keep NFS healthy
          while true; do
            if ! systemctl is-active nfs-kernel-server &>/dev/null; then
              log "WARN: NFS server down, restarting..."
              systemctl restart nfs-kernel-server
            fi

            ACTIVE_EXPORTS=$(exportfs -v 2>/dev/null | grep -c "$EXPORT_PATH" || echo "0")
            if [ "$ACTIVE_EXPORTS" -eq 0 ]; then
              log "WARN: No active exports, re-exporting..."
              exportfs -ra
            fi

            sleep 60
          done
        SCRIPT
      }

      # Configurable via Nomad meta or env vars
      env {
        NFS_EXPORT_PATH   = "/srv/samba/public"
        NFS_TAILSCALE_CIDR = "100.64.0.0/10"
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
