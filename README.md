# monad

Self-managing Nomad cluster for all my needs. GitOps-driven, Claude-managed, Tailscale-networked.

## Quick Start

**Add a new node to the cluster:**
```bash
curl -sL https://raw.githubusercontent.com/claude-monad/monad/main/scripts/setup-node.sh | sudo bash -s -- client 100.78.218.70
```

**Deploy a service:** add a `.hcl` job file to `jobs/`, commit, push. Syncs every 5 min.

## Structure

```
cluster/     - Nomad config templates (server.hcl, client.hcl)
jobs/        - Nomad job specs (GitOps source of truth)
scripts/     - Automation (sync, node setup)
```

## Cluster Info

| Node | Role | Tailscale IP |
|------|------|-------------|
| bigo-server | server+client | 100.78.218.70 |
| bigo-server-oracle | client | 100.119.217.63 |
