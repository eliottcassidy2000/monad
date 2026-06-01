#!/usr/bin/env bash
# run-in-toolchain.sh — run a build/command inside a published toolchain image.
# This is the hybrid-execution bridge: native Claude agents call this to get reproducible
# builds without depending on host toolchain state.
#
# Usage:
#   run-in-toolchain.sh <image> [command...]
#     <image>     lean | compute   (or a full image ref)
#     command...  what to run inside (default: the image's own default cmd)
#
# Examples:
#   run-in-toolchain.sh lean    lake exe cache get && lake build
#   run-in-toolchain.sh compute python3 04-computation/extend_sequence.py
#
# Mounts the current directory at /work. Falls back to podman if docker is absent. If neither
# container runtime exists, runs the command natively (degraded but functional) so a node
# without Docker can still make progress.
set -uo pipefail

KIND="${1:?usage: run-in-toolchain.sh <lean|compute|image-ref> [command...]}"
shift || true

case "$KIND" in
  lean)    IMAGE="ghcr.io/claude-monad/lean-toolchain:latest" ;;
  compute) IMAGE="ghcr.io/claude-monad/compute:latest" ;;
  *)       IMAGE="$KIND" ;;
esac

have() { command -v "$1" >/dev/null 2>&1; }
RUNTIME=""
if have docker; then RUNTIME="docker"
elif have podman; then RUNTIME="podman"
fi

if [ -z "$RUNTIME" ]; then
  printf '\033[0;33m[toolchain]\033[0m no docker/podman — running natively (not reproducible)\n' >&2
  if [ "$#" -eq 0 ]; then exec bash; else exec bash -lc "$*"; fi
fi

printf '\033[0;36m[toolchain]\033[0m %s run %s\n' "$RUNTIME" "$IMAGE" >&2
if [ "$#" -eq 0 ]; then
  exec "$RUNTIME" run --rm -it -v "$PWD:/work" -w /work "$IMAGE"
else
  exec "$RUNTIME" run --rm -v "$PWD:/work" -w /work "$IMAGE" bash -lc "$*"
fi
