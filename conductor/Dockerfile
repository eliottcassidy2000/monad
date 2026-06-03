# monad-conductor — the always-on Cluster Conductor container.
#
# One brain, two front doors:
#   * Tailscale text gateway (conductor/gateway.py) on the host's tailnet address
#   * Remote-control session (`claude --remote-control`) the owner attaches from the app
#
# Runs as the base image's non-root 'ubuntu' user (uid 1000) — Claude refuses
# --dangerously-skip-permissions as root, and uid 1000 matches the host so mounted
# credentials (~/.claude) stay readable/writable (token refresh works).
#
# At runtime (see jobs/cluster-conductor.hcl) we use host networking and MOUNT:
#   - ~/.claude, ~/.claude.json        (Claude OAuth, rw)
#   - the monad repo                   (scripts + GitOps source of truth)
#   - /var/run/tailscale/tailscaled.sock + the host `tailscale` binary  (mesh + ping)
#   - the host `nomad` binary          (cluster ops)
# so the image itself stays lean and never drifts from host tool versions.
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        git python3 python3-pip curl ca-certificates jq tmux \
    && rm -rf /var/lib/apt/lists/*
USER ubuntu
WORKDIR /home/ubuntu
RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/home/ubuntu/.local/bin:/host/bin:${PATH}"
# the conductor scripts come from the mounted monad repo; default command runs them
WORKDIR /work
CMD ["bash", "/work/conductor/start-conductor.sh"]
