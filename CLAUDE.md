# Monad - Self-Managing Nomad Cluster

## What This Is
A GitOps-managed Nomad cluster spanning multiple machines on a Tailscale network.
Claude agents are responsible for managing this cluster by updating git — Nomad
automatically syncs to match what's in the `jobs/` directory every 5 minutes.

## Architecture
- **Bootstrap server**: `bigo-server` (100.78.218.70) — Nomad server + client
- **Worker nodes**: Join via Tailscale, run as Nomad clients
- **GitOps**: `monad-sync` periodic job pulls git and reconciles jobs
- **No Consul** — uses Nomad native service discovery

## Key Paths
- `/etc/nomad.d/nomad.hcl` — Live Nomad config on each node
- `/opt/nomad/data/` — Nomad state directory
- `NOMAD_ADDR=http://100.78.218.70:4646` — Always use this to talk to Nomad

## How to Deploy a New Service
1. Create a `.hcl` job file in `jobs/`
2. Commit and push to `main`
3. The `monad-sync` job will pick it up within 5 minutes
4. Or run `scripts/sync.sh` manually for immediate deployment

## How to Remove a Service
1. Delete the `.hcl` file from `jobs/`
2. Commit and push — sync will stop the job

## How to Add a New Node
Run on the new machine (must have Tailscale):
```bash
curl -sL https://raw.githubusercontent.com/claude-monad/monad/main/scripts/setup-node.sh | sudo bash -s -- client 100.78.218.70
```

## Conventions
- Job files go in `jobs/` with descriptive names matching the job ID
- Use `provider = "nomad"` for service discovery (not Consul)
- Bind services to dynamic ports, let Nomad allocate
- Use `datacenters = ["dc1"]` (default datacenter)
- Constrain server-only tasks with `meta.role = "server"`
- All inter-node communication is over Tailscale

## Nomad Commands
```bash
export NOMAD_ADDR=http://100.78.218.70:4646
nomad server members    # list servers
nomad node status       # list all nodes
nomad status            # list all jobs
nomad job status <name> # details on a job
nomad alloc logs <id>   # view task logs
```
