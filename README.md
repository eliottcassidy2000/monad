# monad

Self-managing Nomad cluster for all my needs. GitOps-driven, Claude-managed, Tailscale-networked.
A Tailscale-networked, Nomad-scheduled fleet of Claude agents doing autonomous pure-math research.

## 🤖 Joining the cluster? Read [JOIN.md](./JOIN.md)

**Are you an AI agent (Claude, ChatGPT, …) that a human pointed at this repo to "join the
cluster" or "add this machine"?** → **[JOIN.md](./JOIN.md) is your instruction set.** It tells
you exactly what to run. The short version, for macOS/Linux:

```bash
curl -sL https://raw.githubusercontent.com/claude-monad/monad/main/meta/bootstrap/join.sh \
  | bash -s -- 100.78.218.70 <max-1|max-2|max-3|pro>
```

One command enrolls this machine: Tailscale + toolchains (Lean, Python, containers, Claude
CLI) + Nomad client + self-healing. The cluster then hands this node the right repos when it
hands it work — you don't pre-clone anything. Full details in [JOIN.md](./JOIN.md).

## Quick Start (existing operators)

**Add a new node (low-level, single step):**
```bash
curl -sL https://raw.githubusercontent.com/claude-monad/monad/main/scripts/setup-node.sh | sudo bash -s -- client 100.78.218.70
```
For a full new machine, prefer the one-command `meta/bootstrap/join.sh` above — it wraps this
plus Tailscale, toolchains, account tagging, and the node-doctor cron.

**Deploy a service:** add a `.hcl` job file to `jobs/`, commit, push. Syncs every 5 min.

## Structure

```
cluster/     - Nomad config templates (server.hcl, client.hcl)
jobs/        - Nomad job specs (GitOps source of truth)
scripts/     - Automation (sync, node setup, monad CLI)
meta/        - Platform layer: cluster join, container toolchains, agent coordination
JOIN.md      - LLM-readable entrypoint for enrolling a new machine
```

## Cluster Info

| Node | Role | Tailscale IP |
|------|------|-------------|
| bigo-server | server+client | 100.78.218.70 |
| bigo-server-oracle | client | 100.119.217.63 |
