# monad

Self-managing Nomad cluster for all my needs. GitOps-driven, Claude-managed, Tailscale-networked.
A Tailscale-networked, Nomad-scheduled fleet of Claude agents doing autonomous pure-math research.

## Joining the cluster? Read [JOIN.md](./JOIN.md)

**Are you an AI agent (Claude, ChatGPT, ...) that a human pointed at this repo to "join the
cluster" or "add this machine"?** → **[JOIN.md](./JOIN.md) is your instruction set.** It tells
you exactly what to run. The short version, for macOS/Linux:

```bash
curl -sL https://raw.githubusercontent.com/claude-monad/monad/main/meta/bootstrap/join.sh | bash
```

One command enrolls this machine. The script auto-discovers the cluster on the Tailscale
network — no server IP or role needed. If no cluster exists, it bootstraps one. Full details
in [JOIN.md](./JOIN.md).

## Quick Start (existing operators)

**Add a new node:** just run the command above. It handles everything:
Tailscale, Nomad (server or client auto-decided), toolchains, Claude CLI, node-doctor cron.

**Deploy a service:** add a `.hcl` job file to `jobs/`, commit, push. Syncs every 5 min.

## Structure

```
cluster/     - Nomad config templates (server.hcl, client.hcl)
jobs/        - Nomad job specs (GitOps source of truth)
scripts/     - Automation (sync, node setup, monad CLI)
meta/        - Platform layer: cluster join, container toolchains, agent coordination
JOIN.md      - LLM-readable entrypoint for enrolling a new machine
```

## Cluster Architecture

The cluster is **self-organizing**:
- Any node can be a server or client — determined automatically at join time
- Server count scales with cluster size (1 for ≤2 nodes, 3 for 3-6, 5 for 7+)
- No hardcoded server IPs — all scripts auto-discover via Tailscale
- Nodes self-heal via `node-doctor` cron (every 8h)
