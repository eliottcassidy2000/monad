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

## Adding a New Node

```bash
curl -sL https://raw.githubusercontent.com/claude-monad/monad/main/scripts/setup-node.sh \
  | sudo bash -s -- client 100.78.218.70
```
