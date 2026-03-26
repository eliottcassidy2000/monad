job "storage-test" {
  datacenters = ["dc1"]
  type        = "batch"

  constraint {
    attribute = "${attr.kernel.name}"
    value     = "linux"
  }

  # NFS test from a remote node using raw_exec (needs root for mount)
  group "nfs-test" {
    count = 1

    constraint {
      attribute = "${meta.role}"
      operator  = "!="
      value     = "storage"
    }

    constraint {
      attribute = "${attr.driver.raw_exec}"
      value     = "1"
    }

    task "test-nfs" {
      driver = "raw_exec"

      config {
        command = "/bin/bash"
        args    = ["local/test.sh"]
      }

      template {
        destination = "local/test.sh"
        perms       = "755"
        data        = <<-SCRIPT
          #!/bin/bash
          set -euo pipefail

          # Discover NFS host dynamically via Nomad service catalog
          NFS_HOST="${NFS_HOST:-}"
          if [ -z "$NFS_HOST" ] && command -v nomad &>/dev/null; then
            NFS_HOST=$(nomad service info nfs-storage 2>/dev/null | awk 'NR==2 {print $4}' | cut -d: -f1 || echo "")
          fi
          # Fallback to known storage node if discovery fails
          NFS_HOST="${NFS_HOST:-100.96.31.66}"
          NFS_SHARE="$NFS_HOST:/"
          MOUNT_POINT="/mnt/nfs-test-$$"
          TEST_DIR="$MOUNT_POINT/nomad-storage/test"
          TEST_FILE="$TEST_DIR/nfs-$(hostname)-$(date +%s).txt"

          log() { echo "[nfs-test $(date '+%H:%M:%S')] $*"; }

          log "=== NFS Storage Test ==="
          log "Host: $(hostname), Target: $NFS_HOST"

          # Ensure nfs client is available
          if ! command -v mount.nfs4 &>/dev/null; then
            log "Installing nfs-common..."
            apt-get update -qq && apt-get install -y -qq nfs-common 2>&1
          fi

          mkdir -p "$MOUNT_POINT"
          log "Mounting $NFS_SHARE..."
          mount -t nfs4 -o soft,timeo=10 "$NFS_SHARE" "$MOUNT_POINT"

          if mountpoint -q "$MOUNT_POINT"; then
            log "OK NFS mount successful"
          else
            log "FAIL mount failed"
            exit 1
          fi

          # Write
          mkdir -p "$TEST_DIR"
          PAYLOAD="NFS test from $(hostname) at $(date)"
          echo "$PAYLOAD" > "$TEST_FILE"
          log "OK Write passed"

          # Read
          if [ "$(cat "$TEST_FILE")" = "$PAYLOAD" ]; then
            log "OK Read passed"
          else
            log "FAIL Read mismatch"
            umount "$MOUNT_POINT"; exit 1
          fi

          # Speed test
          log "Write speed test (100MB)..."
          dd if=/dev/zero of="$TEST_DIR/speed.bin" bs=1M count=100 2>&1 | grep -i copied
          rm -f "$TEST_DIR/speed.bin"

          # Info
          df -h "$MOUNT_POINT"
          ls -la "$TEST_DIR"

          umount "$MOUNT_POINT"
          rmdir "$MOUNT_POINT" 2>/dev/null || true
          log "=== All NFS tests PASSED ==="
        SCRIPT
      }

      resources {
        cpu    = 200
        memory = 256
      }
    }
  }

  # Direct host_volume test on death-star
  group "volume-test" {
    count = 1

    constraint {
      attribute = "${meta.role}"
      value     = "storage"
    }

    constraint {
      attribute = "${attr.driver.docker}"
      value     = "1"
    }

    volume "storage" {
      type      = "host"
      source    = "storage"
      read_only = false
    }

    task "test-volume" {
      driver = "docker"

      config {
        image      = "alpine:latest"
        entrypoint = ["/bin/sh"]
        command    = "/local/test.sh"
      }

      volume_mount {
        volume      = "storage"
        destination = "/data"
        read_only   = false
      }

      template {
        destination = "local/test.sh"
        perms       = "755"
        data        = <<-SCRIPT
          #!/bin/sh
          set -eu

          TEST_DIR="/data/nomad-storage/test"
          TEST_FILE="$TEST_DIR/volume-$(date +%s).txt"

          echo "[volume-test] Host volume test on death-star"

          mkdir -p "$TEST_DIR"
          echo "Host volume works at $(date)" > "$TEST_FILE"
          cat "$TEST_FILE"
          echo "[volume-test] OK read/write works"

          echo "[volume-test] Storage:"
          ls -la /data/ | head -15
          df -h /data

          echo "[volume-test] === PASSED ==="
        SCRIPT
      }

      resources {
        cpu    = 100
        memory = 64
      }
    }
  }
}
