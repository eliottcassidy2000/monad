# Monad — Self-Managing Nomad Cluster

## What This Is
A GitOps-managed Nomad cluster spanning machines on a Tailscale network.
Claude agents are the primary operators. Git is the source of truth.

## Architecture
- **Bootstrap server**: `bigo-server` (100.78.218.70) — Nomad server + client
- **Worker nodes**: Join via Tailscale, run as Nomad clients
- **GitOps**: `monad-sync` periodic job pulls git every 5 min, reconciles `jobs/`
- **Service discovery**: Nomad native (no Consul)
- **Networking**: All inter-node traffic over Tailscale

## The `monad` CLI

**All agents MUST use `monad` for git, nomad, deploy, and GitHub operations.**
Do not use raw `git`, `nomad`, or `gh` commands directly.

```bash
monad help                          # full command reference

# Git (always pulls before commit, standardizes messages)
monad git pull                      # fetch + ff-merge origin/main
monad git status                    # short status
monad git commit "description"      # stage all + commit with Co-Authored-By
monad git push                      # push main to origin
monad git sync                      # pull, auto-commit if dirty, push

# Nomad (NOMAD_ADDR handled automatically)
monad nomad status                  # list jobs
monad nomad nodes                   # list nodes
monad nomad servers                 # list server members
monad nomad job-status <job>        # job details
monad nomad alloc-logs <alloc>      # stdout + stderr
monad nomad alloc-status <alloc>    # allocation details

# Deploy (validate → plan → run → commit → push, in one step)
monad deploy <file.hcl>             # deploy a job
monad undeploy <job-name>           # stop + remove + commit + push
monad sync                          # force immediate GitOps sync
monad validate <file.hcl>           # validate without deploying

# Cluster
monad cluster-status                # full health overview

# GitHub
monad gh issue "title" "body"       # create issue
monad gh issues                     # list open issues
```

## Agent Rules

1. **Always use `monad` CLI** — never raw git/nomad/gh commands
2. **Pull before you write** — run `monad git pull` before modifying any file
3. **Commit messages are imperative, lowercase** — "add traefik reverse proxy", not "Added Traefik"
4. **One concern per commit** — don't bundle unrelated changes
5. **Validate before deploy** — `monad validate` before `monad deploy`
6. **Job files go in `jobs/`** — filename must match the job ID (e.g., `traefik.hcl` for job "traefik")
7. **Use `monad deploy`** — it validates, plans, runs, commits, and pushes atomically
8. **Check status after deploy** — `monad nomad job-status <job>` to confirm healthy
9. **Don't touch cluster configs directly** — templates live in `cluster/`, live configs are on nodes
10. **Log your reasoning in commit messages** — the message should explain *why*, not *what*

## Repo Structure

```
jobs/        — Nomad job specs (source of truth for what runs)
cluster/     — Config templates for server.hcl and client.hcl
scripts/     — monad CLI, sync.sh, setup-node.sh
```

## Job Spec Conventions

- `datacenters = ["dc1"]`
- `provider = "nomad"` for service blocks
- Dynamic ports — let Nomad allocate
- Constrain server-only tasks: `attribute = "${meta.role}"` / `value = "server"`
- Resource limits on every task (cpu + memory)
- Use Docker driver for application workloads, raw_exec only for system tasks

## Cluster Mission: Autonomous Math Research

The primary workload of this cluster is **autonomous pure mathematics research**, powered by
Claude Code instances running as Nomad batch jobs against the tournament theory repository:

- **Upstream**: `eliottcassidy2000/math` — deep research on tournaments (complete directed
  graphs), their combinatorial/algebraic/topological properties, 114+ theorems, 150+ computation
  scripts, OEIS contributions, and engineering applications
- **The math repo has its own CLAUDE.md** with a mandatory startup sequence, agent messaging
  system, court dispute system, and session logging protocol. All research agents MUST follow it.

### Research Job Architecture

Three autonomous agent types run on the cluster:

| Job | Schedule | Role |
|-----|----------|------|
| `math-researcher` | Every 6h | Deep research sessions — proves theorems, explores connections, writes up results |
| `math-quick-compute` | Every 2h | Pure computation — runs scripts, extends sequences, generates data |
| `math-reviewer` | Daily 3 AM | Quality control — verifies results, checks for mistakes, synthesizes daily progress |

All jobs clone the math repo, run a Claude Code session with a specific focus, commit results,
and push. The math repo's own agent coordination system (`agents/processor.py`) handles
inter-agent messaging.

### API Key Management

Research jobs need `ANTHROPIC_API_KEY` set as a Nomad variable or passed via environment.
Use Nomad variables to store secrets:
```bash
nomad var put nomad/jobs/math-researcher ANTHROPIC_API_KEY=sk-ant-...
```

### Scaling Strategy

- **Compute-heavy work** (sequence enumeration, large n tournaments): prefer `death-star` or Linux nodes with raw CPU
- **Research sessions** (reasoning, proof construction): any node with Claude Code installed
- **Review/synthesis**: runs on server node for access to full git history
- Future: add GPU nodes for ML-adjacent tasks (tournament TDA, polynomial_head experiments)

## Nodes

| Node | IP | OS | Role | Capabilities |
|------|----|----|------|-------------|
| `bigo-server` | 100.78.218.70 | Linux | server + client | Docker, raw_exec, monad-repo volume |
| `bigo-server-oracle` | 100.119.217.63 | Linux | client | Docker, raw_exec |
| `death-star` | 100.96.31.66 | Linux | client | Docker, raw_exec |
| `V1410-1` | 100.75.75.39 | Linux | client | Docker, raw_exec |
| `windesk` | 100.94.210.54 | Windows | client | raw_exec, Claude Code native |

## Adding a New Node

### Linux
```bash
curl -sL https://raw.githubusercontent.com/claude-monad/monad/main/scripts/setup-node.sh \
  | sudo bash -s -- client 100.78.218.70
```

### Windows
```powershell
# Install Nomad
scoop install nomad

# Create config (see cluster/client-windows.hcl template)
mkdir C:\nomad\config C:\nomad\data
# Edit C:\nomad\config\nomad.hcl with your Tailscale IP

# Start agent
nomad agent -config=C:\nomad\config\nomad.hcl
```
