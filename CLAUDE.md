# Monad — Self-Managing Nomad Cluster

## What This Is
A GitOps-managed Nomad cluster spanning machines on a Tailscale network.
Claude agents are the primary operators. Git is the source of truth.
The cluster's mission is **autonomous pure mathematics research**.

## Architecture
- **Bootstrap server**: `bigo-server` (100.78.218.70) — Nomad server + client
- **Worker nodes**: Join via Tailscale, run as Nomad clients
- **GitOps**: `monad-sync` periodic job pulls git every 5 min, reconciles `jobs/`
- **Service discovery**: Nomad native (no Consul)
- **Networking**: All inter-node traffic over Tailscale
- **Self-healing**: `node-doctor` runs on each node via OS cron (not Nomad)

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
cluster/     — Config templates for server.hcl, client.hcl, client-windows.hcl
scripts/     — monad CLI, sync.sh, setup-node.sh, key-ring.sh, node-doctor.sh
logs/        — node-doctor reports (only committed when issues found)
```

## Job Spec Conventions

- `datacenters = ["dc1"]`
- `provider = "nomad"` for service blocks
- Dynamic ports — let Nomad allocate
- Constrain server-only tasks: `attribute = "${meta.role}"` / `value = "server"`
- Resource limits on every task (cpu + memory)
- Use Docker driver for application workloads, raw_exec for system tasks and Claude sessions

---

## Cluster Mission: Autonomous Math Research

The primary workload is **autonomous pure mathematics research** on tournament theory,
powered by Claude Code instances running as Nomad batch jobs.

### The Math Repo

- **Upstream**: `eliottcassidy2000/math`
- **Subject**: Tournaments (complete directed graphs) — Hamiltonian path counts H(T),
  the formal group F(x,y)=(x+y)/(1+xy), path homology, Krawtchouk analysis, OEIS sequences
- **Scale**: 114+ theorems proved, 150+ computation scripts, 90+ OEIS sequences extended
- **The math repo has its own CLAUDE.md** with a mandatory startup sequence, multi-agent
  messaging system (`agents/processor.py`), court dispute system, and session logging.
  **All research agents MUST follow it.**

### The Three Research Agents

| Job | Schedule | Key | Role |
|-----|----------|-----|------|
| `math-researcher` | Every 6h | MAX_KEY_1 | Deep research — proves theorems, explores connections, writes up results. Day-of-week rotation covers the full research frontier. |
| `math-quick-compute` | Every 2h | MAX_KEY_2 | Pure computation — runs scripts, extends sequences, generates data. No theorizing, just crunch numbers. |
| `math-reviewer` | Daily 3 AM | MAX_KEY_3 | Quality control — verifies results against MISTAKES.md, opens court cases for dubious claims, synthesizes daily progress, coordinates other agents. |

The agents use the math repo's built-in coordination:
- **Session letters** via `agents/processor.py --send` — structured handoff between sessions
- **Court cases** in `02-court/active/` — formal dispute resolution when results conflict
- **Session log** in `00-navigation/SESSION-LOG.md` — chronological record of all work
- **Knowledge base** in `05-knowledge/` — results, hypotheses, variables

### Day-of-Week Research Rotation (math-researcher)

| Day | Focus |
|-----|-------|
| Mon | Highest-priority open question — attempt proof or significant partial result |
| Tue | Computation — run scripts, extend OEIS sequences, verify conjectures |
| Wed | Hypothesis testing — prove or refute entries from hypotheses/INDEX.md |
| Thu | Cross-domain connections — develop tangents from TANGENTS.md into results |
| Fri | Engineering — build tools, improve scripts, create visualizations |
| Sat | Write-up — clean proofs for 01-canon/theorems/ from raw results |
| Sun | Free exploration — follow curiosity through CONCEPT-MAP.md |

---

## API Key Architecture

### The 4 Accounts

| Account | Type | Purpose | Rate Limits |
|---------|------|---------|-------------|
| MAX_KEY_1 | Max | math-researcher sessions | High context, high rate |
| MAX_KEY_2 | Max | math-quick-compute sessions | High context, high rate |
| MAX_KEY_3 | Max | math-reviewer sessions | High context, high rate |
| PRO_KEY | Pro | node-doctor on every machine | Sufficient for short maintenance sessions |

### Key Storage

All keys are stored as Nomad variables (encrypted at rest):

```bash
export NOMAD_ADDR=http://100.78.218.70:4646

nomad var put nomad/jobs/key-ring \
  MAX_KEY_1=sk-ant-... \
  MAX_KEY_2=sk-ant-... \
  MAX_KEY_3=sk-ant-... \
  PRO_KEY=sk-ant-...
```

### Key Selection: `scripts/key-ring.sh`

The key-ring script handles selection and rotation:

```bash
eval $(scripts/key-ring.sh research)     # → exports MAX_KEY_1
eval $(scripts/key-ring.sh compute)      # → exports MAX_KEY_2
eval $(scripts/key-ring.sh review)       # → exports MAX_KEY_3
eval $(scripts/key-ring.sh doctor)       # → exports PRO_KEY
eval $(scripts/key-ring.sh round-robin)  # → rotates across Max keys by hour
```

**Dedicated strategy** (default): Each job type gets its own Max key. This avoids
cross-job rate limit contention — if the researcher is mid-session, the compute
agent isn't competing for the same key's rate limit.

**Round-robin strategy** (`MONAD_KEY_STRATEGY=round-robin`): Rotates across all 3 Max
keys by hour. Better if one account is temporarily rate-limited or down.

### Cost Management

- **Max keys**: ~$200/mo each, used for substantive research work
- **Pro key**: ~$20/mo, used ONLY for node-doctor maintenance (short sessions, ~3/day/node)
- **Budget envelope**: ~$620/mo total
- All research jobs have `prohibit_overlap = true` — no parallel key usage for same job type
- The reviewer runs once daily (1 session/day on MAX_KEY_3)
- The researcher runs 4 sessions/day (every 6h on MAX_KEY_1)
- The compute agent runs 12 sessions/day (every 2h on MAX_KEY_2) — but sessions are short

---

## Self-Healing: The Node Doctor

Every node runs `scripts/node-doctor.sh` via **OS-native cron** (not Nomad). This is
critical — if Nomad itself dies on a node, Nomad-scheduled jobs can't fix it. Only the
node-doctor can.

### What It Checks

1. **Tailscale connectivity** — can we reach the mesh?
2. **Nomad server reachability** — can we reach bigo-server:4646?
3. **Nomad agent health** — is the local agent running and eligible?
4. **Git state** — is the repo clean, up to date, no conflicts?
5. **Disk space** — are we running out?
6. **Claude CLI availability** — can this node run research jobs?

### What It Does When Things Break

If any check fails and Claude Code + PRO_KEY are available:
- Spawns a short Claude session to diagnose and fix the issue
- Restarts Nomad if it crashed
- Resolves git conflicts
- Cleans disk space
- Reports the issue to the cluster via git commit

If Claude is unavailable, it logs the issue for manual intervention.

### Installation

**Linux:**
```bash
crontab -e
# Add: 0 */8 * * * /path/to/monad/scripts/node-doctor.sh >> /var/log/node-doctor.log 2>&1
```

**Windows:**
```powershell
schtasks /create /tn "NodeDoctor" /tr "bash C:\Users\Eliott\monad\scripts\node-doctor.sh" /sc daily /st 06:00 /ri 480 /du 24:00
```

### Healthy nodes produce no output
Only issues and warnings are committed. Healthy checks are silent. This prevents log
noise while ensuring every problem is git-tracked and visible to the cluster.

---

## Nodes

| Node | IP | OS | Role | Capabilities |
|------|----|----|------|-------------|
| `bigo-server` | 100.78.218.70 | Linux | server + client | Docker, raw_exec, monad-repo volume |
| `bigo-server-oracle` | 100.119.217.63 | Linux | client | Docker, raw_exec |
| `death-star` | 100.96.31.66 | Linux | client | Docker, raw_exec |
| `V1410-1` | 100.75.75.39 | Linux | client | Docker, raw_exec |
| `windesk` | 100.94.210.54 | Windows | client | raw_exec, Claude Code native |

### Offline (potential future nodes)

| Node | IP | OS | Last Seen | Notes |
|------|----|----|-----------|-------|
| `eliottdesk` | 100.123.35.50 | Linux | 22d ago | Desktop |
| `eliotts-mac-mini` | 100.113.252.45 | macOS | 4d ago | Mac Mini |
| `sdxlemur-2` | 100.91.113.19 | Linux | 4d ago | Recent |
| `pi0`, `pi1` | various | Linux | months | Raspberry Pis |
| `micro-1..4-google` | various | Linux | ~1y | Google Cloud micros |

## Adding a New Node

### Linux
```bash
curl -sL https://raw.githubusercontent.com/claude-monad/monad/main/scripts/setup-node.sh \
  | sudo bash -s -- client 100.78.218.70
```

### Windows
```powershell
scoop install nomad
mkdir C:\nomad\config C:\nomad\data
# Copy cluster/client-windows.hcl → C:\nomad\config\nomad.hcl, fill in your Tailscale IP
nomad agent -config=C:\nomad\config\nomad.hcl
```

### After joining
1. Install Claude Code CLI on the node
2. Set up node-doctor cron (see Self-Healing section)
3. Verify: `monad nomad nodes` should show the new node as `ready`
