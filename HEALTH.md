# Prime Directive: Maintain Cluster Health

**This is the standing task for every agent on every node, in every session — ongoing, never
"done."** You are responsible not only for your own node but for the **constant health of all
the others**. Monitor your peers continuously, and when one degrades, **take action on your own
initiative**: spawn programs, deploy Nomad jobs, open repair sessions, file issues — whatever it
takes to bring the fleet back to full health. Do not wait to be asked.

## The fleet (6 nodes)

| Node | Tailscale IP | OS | Role |
|------|--------------|----|------|
| `v1410-1` | 100.75.75.39 | Linux | server / leader, home router, IPv4 egress via oraclebox1 |
| `oraclebox1` | 100.125.210.126 | Linux | client, Tailscale exit node (cloud, always-on) |
| `claudebox` | 100.87.219.108 | Linux | client (home LAN) |
| `bigo-server` | 100.78.218.70 | Linux | client (storage) |
| `windesk` | 100.94.210.54 | Windows | client |
| `eliotts-mac-mini` | 100.113.252.45 | macOS | client |

Keep this roster in sync with `scripts/connectivity-probe.sh` (the metric reads from there).

## What "healthy" means — for every node

1. **On the tailnet** — reachable, `Online` in `tailscale status`.
2. **A working cluster node** — Linux nodes registered + `ready` in `monad nomad nodes`; their
   keepalive running (`claudebox-client.sh keepalive` cron on Linux clients; node-manager
   scheduled task on Windows).
3. **Self-monitoring alive** — `node-doctor` report is fresh (cron every 8h); `cluster-watchdog`
   running on the server.
4. **Resources OK** — disk and memory below thresholds, not trending toward full.
5. **Compute available** — Claude and/or Codex CLI usable so the node can run work.
6. **Routing intact** — internet reaches the LAN (see [NETWORKING.md](./NETWORKING.md): IPv4 via
   the oraclebox1 exit node, IPv6 native).

## How to monitor your peers

- `monad cluster-status` / `monad pulse` — full health overview.
- `monad nomad nodes` — who's `ready`.
- `scripts/connectivity-probe.sh` — per-node tailnet+Nomad score (→ `logs/metrics/`).
- `scripts/net-diag.sh` — per-node internet path (the `net-diag` system job runs it on every node).
- `tailscale status` — mesh reachability and last-seen.
- `logs/events.jsonl` — the cluster audit trail; `logs/doctor-*` — node-doctor reports.

## When a peer is unhealthy — ACT (examples, not limits)

- **Peer's Nomad agent died / node not `ready`** → redeploy/restart its keepalive; if a Linux
  client, ensure `claudebox-client.sh` (or the equivalent) is installed and running.
- **Peer off the tailnet** → it can't be reached directly; from a healthy node, record the outage
  to `events.jsonl`, open a GitHub issue, and (for LAN machines) note the specific link to fix.
- **A node missing entirely from the cluster** → it likely needs to (re)join: `meta/bootstrap/join.sh`.
- **Disk/memory trending to full** → spawn a cleanup job on that node before it tips over.
- **A needed service is down** (storage, monitoring, exit-node routing) → redeploy the job from `jobs/`.
- **No watchdog/doctor reports arriving** → the self-healing itself is broken; investigate first.
- **Gaps in coverage** → if the fleet lacks a monitor for some failure mode, **build one** (a
  script in `scripts/`, a Nomad job in `jobs/`) and deploy it. "Spawn programs as needed."

## Rules of engagement

- **Healthy is silent.** Only problems, actions taken, and fixes get logged/committed — keeps the
  audit trail signal-rich.
- **Log what you do** to `logs/events.jsonl` (schema: `{ts,node,source,action,result,detail}`) and,
  for anything non-trivial, a GitHub issue via `monad gh issue`.
- **Use the `monad` CLI** for all git/nomad/gh actions; pull before you write; deploy via `monad deploy`.
- **Don't destabilize to stabilize** — prefer additive repair (new job, restart) over ripping out
  working config. The server (`v1410-1`) is the permanent leader; never give intermittent nodes
  `bootstrap_expect`.
- This directive **composes with** [MISSION.md](./MISSION.md) (connectivity & uptime) and
  [NETWORKING.md](./NETWORKING.md) (the internet path) — those are facets of cluster health.

## Field notes (append as you learn)

- **2026-06-02** — Prime directive established: every node maintains the health of all others and
  spawns programs as needed. Fleet set to the 6 nodes above; `connectivity-probe.sh` roster
  expanded to match. `agent-maint-*` sessions are already appearing on the tailnet — that is this
  directive in action.
