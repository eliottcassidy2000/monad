#!/usr/bin/env bash
# push-image.sh — build the conductor image and push it to GHCR, then store the
# pull token as an encrypted Nomad variable so jobs/cluster-conductor.hcl can pull
# it. Requires a gh token with write:packages,read:packages
# (grant once: gh auth refresh -s write:packages,read:packages).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="ghcr.io/eliott-monad/monad-conductor:latest"
USER_NS="eliottcassidy2000"
export NOMAD_ADDR="${NOMAD_ADDR:-http://$(tailscale ip -4 2>/dev/null | head -1):4646}"

TOKEN="$(gh auth token)"
echo "[push] checking token scopes..."
if ! gh auth status 2>&1 | grep -q "write:packages"; then
  echo "[push] ERROR: gh token lacks 'write:packages'. Run:" >&2
  echo "         gh auth refresh -s write:packages,read:packages" >&2
  exit 1
fi

echo "[push] building $IMAGE (classic builder)"
sudo DOCKER_BUILDKIT=0 docker build -t "$IMAGE" -f "$HERE/Dockerfile" "$HERE"

echo "[push] docker login ghcr.io"
echo "$TOKEN" | sudo docker login ghcr.io -u "$USER_NS" --password-stdin

echo "[push] pushing $IMAGE"
sudo docker push "$IMAGE"

echo "[push] storing pull token in Nomad var secret/conductor (key ghcr_token)"
EXISTING_GH="$(nomad var get -out json secret/conductor 2>/dev/null \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["Items"].get("github_token",""))' 2>/dev/null || true)"
nomad var put -force secret/conductor github_token="${EXISTING_GH:-$TOKEN}" ghcr_token="$TOKEN" >/dev/null
echo "[push] done. Image on GHCR + pull token stored."
echo "[push] next: cut over to the Nomad-managed conductor:"
echo "         sudo docker rm -f cluster-conductor   # free :8200"
echo "         nomad job run jobs/cluster-conductor.hcl"
