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
| `death-star` | 100.96.31.66 | Linux | client (storage, home LAN) — **onboarding (see Active Projects)** |
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

## Active Projects

### 🟡 Onboard `death-star` (storage node) — get it fully functional

**Owner: the maintainers (all nodes).** `death-star` (`100.96.31.66`, LAN `192.168.51.14`,
SuperMicro storage box) joined but is **not yet fully functional**. Drive it to green.

**State (2026-06-03):**
- On the LAN + tailnet; reachable from V1410 (ping, SSH `:22` open); getting IPv6 via SLAAC
  (`fd00:51::…`). ✅
- Reported symptom: **HTTP/ping work but no HTTPS** — the classic MTU black hole. Almost
  certainly because death-star uses **jumbo frames (MTU 9000)**: it advertised a huge MSS, so
  TLS cert packets overflowed the 1472 WAN and were dropped upstream with no PMTUD.
- **Likely already fixed at the source:** V1410's new **MSS-clamp** (`table inet monad_mss`)
  rewrites every forwarded SYN's MSS to fit the WAN (verified `1460→1432` on the wire), which
  works regardless of client MTU. See [NETWORKING.md](./NETWORKING.md).

**Tasks:**
1. **Verify HTTPS now works from death-star itself** (`curl -4 https://www.cloudflare.com/`).
   If it still fails, check `ip link` on death-star — if MTU is 9000, the V1410 clamp should
   still cover it; as a belt-and-suspenders, set death-star's NIC to 1500 or add
   `dhcp-option=interface:eno3,option:mtu,1472` on V1410's dnsmasq.
2. **Sort out access** — key-based SSH login failed from V1410; maintainers need a working
   credential to operate it.
3. **Make it a real cluster node** — install/run the Nomad client (`scripts/setup-node.sh` /
   `claudebox-client.sh`) so it registers `ready` (currently LAN-only, not Nomad-joined), and
   ensure `tailscale up` keeps it on the mesh.
4. **Light up its storage role** — point the storage jobs (`jobs/nfs-storage.hcl`,
   `jobs/minio-storage.hcl`) at it once it's `ready`.
5. **Close the loop** — death-star is already in the `connectivity-probe` roster; it should go
   from tailnet-only to fully `connected`. Log progress to `events.jsonl`.

## Field notes (append as you learn)

- **2026-06-02** — Prime directive established: every node maintains the health of all others and
  spawns programs as needed. Fleet set to the 6 nodes above; `connectivity-probe.sh` roster
  expanded to match. `agent-maint-*` sessions are already appearing on the tailnet — that is this
  directive in action.
- **2026-06-03** — Fixed LAN HTTPS *natively* (no exit node): the "HTTP works, HTTPS doesn't"
  symptom was an MTU black hole (WAN 1472 vs client 1500). Added an MSS clamp on V1410
  (`table inet monad_mss`, verified `1460→1432`) and tore down the oraclebox1 exit-node
  scaffolding. Added `death-star` (7th node) and opened its onboarding project above.
