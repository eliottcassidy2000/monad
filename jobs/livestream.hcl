job "livestream" {
  datacenters = ["dc1"]
  type        = "service"

  # Run on bigo-server-oracle (best bandwidth)
  constraint {
    attribute = "${attr.unique.hostname}"
    value     = "bigo-server-oracle"
  }

  group "stream" {
    count = 1

    network {
      # RTMP ingest — OBS sends here
      port "rtmp" {
        static = 1935
      }
      # Web dashboard
      port "dashboard" {
        static = 8080
      }
      # nginx HTTP (HLS + stats)
      port "http" {
        static = 8088
      }
    }

    # Use raw_exec so we can install/run nginx-rtmp + ffmpeg + python natively
    # This avoids Docker image build complexity and gives direct network access
    task "livestream" {
      driver = "raw_exec"

      config {
        command = "/bin/bash"
        args    = ["local/run.sh"]
      }

      template {
        destination = "local/run.sh"
        perms       = "755"
        data        = <<-SCRIPT
          #!/bin/bash
          set -euo pipefail

          MONAD_DIR="${MONAD_REPO_DIR:-/home/bigo/monad}"
          STREAM_DIR="$MONAD_DIR/livestream"
          PID_DIR="/tmp/livestream-pids"
          HLS_DIR="/tmp/hls"
          HLS_COMP_DIR="/tmp/hls-composite"

          mkdir -p "$PID_DIR" "$HLS_DIR" "$HLS_COMP_DIR"

          log() { echo "[livestream $(date '+%H:%M:%S')] $*"; }

          # ── Install dependencies if needed ──
          install_deps() {
            local needs_install=false

            if ! command -v nginx &>/dev/null; then needs_install=true; fi
            if ! command -v ffmpeg &>/dev/null; then needs_install=true; fi
            if ! python3 -c "import flask" 2>/dev/null; then needs_install=true; fi

            if $needs_install; then
              log "Installing dependencies..."
              export DEBIAN_FRONTEND=noninteractive

              # Add nginx RTMP PPA if not present
              if ! dpkg -l | grep -q libnginx-mod-rtmp; then
                apt-get update -qq
                apt-get install -y -qq nginx libnginx-mod-rtmp ffmpeg python3-pip python3-flask python3-requests 2>&1
              fi
            fi

            log "Dependencies ready"
          }

          # ── Configure nginx ──
          setup_nginx() {
            # Copy our RTMP-enabled config
            cp "$STREAM_DIR/nginx.conf" /etc/nginx/nginx.conf

            # Test config
            if nginx -t 2>&1; then
              log "nginx config OK"
            else
              log "ERROR: nginx config invalid"
              exit 1
            fi
          }

          # ── Start nginx ──
          start_nginx() {
            if pgrep -x nginx &>/dev/null; then
              log "nginx already running, reloading config..."
              nginx -s reload
            else
              log "Starting nginx-rtmp..."
              nginx
            fi
          }

          # ── Start dashboard ──
          start_dashboard() {
            log "Starting dashboard on :8080..."
            cd "$STREAM_DIR"
            python3 dashboard.py &
            echo $! > "$PID_DIR/dashboard.pid"
          }

          # ── Cleanup on exit ──
          cleanup() {
            log "Shutting down..."
            # Stop dashboard
            if [ -f "$PID_DIR/dashboard.pid" ]; then
              kill "$(cat "$PID_DIR/dashboard.pid")" 2>/dev/null || true
            fi
            # Stop nginx
            nginx -s stop 2>/dev/null || true
            log "Shutdown complete"
          }
          trap cleanup EXIT

          # ── Main ──
          install_deps
          setup_nginx
          start_nginx
          start_dashboard

          log "Livestream system ready!"
          log "  RTMP ingest: rtmp://$(tailscale ip -4 2>/dev/null || echo 'localhost'):1935/live/<key>"
          log "  Dashboard:   http://$(tailscale ip -4 2>/dev/null || echo 'localhost'):8080"

          # Keep running — watchdog loop
          while true; do
            # Check nginx
            if ! pgrep -x nginx &>/dev/null; then
              log "WARN: nginx died, restarting..."
              start_nginx
            fi

            # Check dashboard
            if [ -f "$PID_DIR/dashboard.pid" ]; then
              if ! kill -0 "$(cat "$PID_DIR/dashboard.pid")" 2>/dev/null; then
                log "WARN: dashboard died, restarting..."
                start_dashboard
              fi
            fi

            sleep 30
          done
        SCRIPT
      }

      resources {
        cpu    = 2000
        memory = 2048
      }

      service {
        name     = "livestream-rtmp"
        port     = "rtmp"
        provider = "nomad"

        check {
          type     = "tcp"
          port     = "rtmp"
          interval = "30s"
          timeout  = "5s"
        }
      }

      service {
        name     = "livestream-dashboard"
        port     = "dashboard"
        provider = "nomad"

        check {
          type     = "http"
          path     = "/"
          port     = "dashboard"
          interval = "30s"
          timeout  = "5s"
        }
      }
    }
  }
}
