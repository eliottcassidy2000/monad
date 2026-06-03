#!/usr/bin/env bash
# redeploy.sh — (re)build the conductor image and (re)launch it as an always-on
# container on this node (oraclebox1). Docker's own restart policy keeps it up
# across crashes and reboots. Idempotent: safe to re-run after changing the code.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONAD_ROOT="$(cd "$HERE/.." && pwd)"

MYIP="$(tailscale ip -4 2>/dev/null | head -1)"
[ -n "$MYIP" ] || { echo "no tailscale IP; is tailscale up?" >&2; exit 1; }
PORT="${CONDUCTOR_PORT:-8200}"

echo "[redeploy] building monad-conductor image (classic builder so Nomad/Docker see it locally)"
sudo DOCKER_BUILDKIT=0 docker build -t monad-conductor:latest -f "$HERE/Dockerfile" "$HERE"

echo "[redeploy] (re)launching container"
sudo docker rm -f cluster-conductor 2>/dev/null || true
TOKEN="$(gh auth token 2>/dev/null || true)"
sudo docker run -d --restart unless-stopped --name cluster-conductor \
  --network host \
  -v /home/ubuntu/.claude:/home/ubuntu/.claude \
  -v /home/ubuntu/.claude.json:/home/ubuntu/.claude.json \
  -v "$MONAD_ROOT":/work \
  -v /var/run/tailscale:/var/run/tailscale \
  -v /usr/bin/nomad:/host/bin/nomad:ro \
  -v /usr/bin/tailscale:/host/bin/tailscale:ro \
  -e NOMAD_ADDR="http://${MYIP}:4646" \
  -e CONDUCTOR_WORKDIR=/work \
  -e CONDUCTOR_PORT="$PORT" \
  -e MONAD_REPO_DIR=/work \
  ${CONDUCTOR_TOKEN:+-e CONDUCTOR_TOKEN="$CONDUCTOR_TOKEN"} \
  -e GH_TOKEN="$TOKEN" \
  monad-conductor

echo "[redeploy] waiting for the gateway..."
for i in $(seq 1 20); do
  if curl -s --max-time 4 "http://${MYIP}:${PORT}/health" >/dev/null 2>&1; then
    echo "[redeploy] conductor up:  http://${MYIP}:${PORT}/  (POST /ask)"
    exit 0
  fi
  sleep 3
done
echo "[redeploy] gateway did not answer in time; check: sudo docker logs cluster-conductor" >&2
exit 1
