# Mission: Full Cluster Connectivity & Uptime

**This is a shared goal for every machine in the monad cluster. If you are a Claude agent
running on any node, this is yours to work on — from your own end.**

The objective is simple and measurable: get **all roster machines connected at the same
time, and keep them that way**. "Connected" means a node is *both* on the Tailscale mesh
*and* registered + `ready` as a Nomad node. We track it as a single number, the
**connectivity score = connected / expected**, and drive it toward **100%** with high uptime.

## How this is measured (in Nomad)

- **Job:** `jobs/cluster-connectivity.hcl` — a Nomad **periodic batch** that runs every 5 min
  on the always-on server (V1410-1) and calls `scripts/connectivity-probe.sh`.
- **Per-sample data:** `logs/metrics/connectivity.csv` (`epoch,node,tailnet_online,nomad_ready,connected`).
- **Current snapshot + rolling uptime per node:** `logs/metrics/connectivity-latest.json`.
- **Event stream:** each run appends a `source:"connectivity"` line to `logs/events.jsonl`.
- **Check it anytime:** `scripts/connectivity-probe.sh` (prints the live table) or
  `monad nomad job-status cluster-connectivity`.

The roster lives at the top of `scripts/connectivity-probe.sh`. **Add your machine there**
(name + Tailscale IP) and commit, so it counts toward the score.

## Baseline (2026-06-01) — score 25% (1/4)

| Node | Tailnet | Nomad | Connected | The blocker to fix from your end |
|------|---------|-------|-----------|----------------------------------|
| **V1410-1** (100.75.75.39) | online | ready | ✅ | Anchor. Keep Tailscale + Nomad server + dnsmasq up. It's the home router → online ~always. |
| **claudebox** (100.87.219.108) | **offline** | – | ❌ | Machine is **alive on the LAN** (192.168.51.19) but its **tailnet link is down**. Run `sudo tailscale up`, then `~/monad/scripts/claudebox-client.sh start` and install its keepalive cron. You join V1410-1 as a **client** (never a server). |
| **windesk** (100.94.210.54) | online | – | ❌ | On the tailnet but **no Nomad client installed**. Install Nomad **2.0.2** from `cluster/client-windows.hcl`, point `server_join` at `100.75.75.39:4647`, register the node-manager scheduled task. |
| **eliotts-mac-mini** (100.113.252.45) | **offline** | – | ❌ | Powered off / asleep and not on the LAN (no Wake-on-LAN path from the router). Needs a power-on; then ensure `tailscale up` and run `join.sh` (auto-joins as a client). |

## What every node should do

1. **Get yourself connected** — fix your row above. Both signals must be green: tailnet *and* Nomad-ready.
2. **Stay connected** — install/verify your keepalive (`claudebox-client.sh keepalive` cron on
   Linux clients; node-manager scheduled task on Windows). The node-doctor (`scripts/node-doctor.sh`,
   every 8h) already checks Tailscale + server reachability — let it self-heal and report.
3. **Troubleshoot and share ideas** — this is a collaborative goal:
   - Log what you find to `logs/events.jsonl` with `"source":"connectivity"` (matches the probe's schema).
   - Add durable findings to the **Field notes** section below and `monad git commit`/`push`.
   - When GitHub auth is working, mirror discussion to an issue titled
     *"cluster connectivity & uptime"* via `monad gh issue` so there's one live thread.
4. **Don't regress the topology** — V1410-1 is the single permanent server. Intermittent
   machines join as **clients only**; never give them `bootstrap_expect` (two unconnected
   `bootstrap_expect=1` servers form two clusters that can't see each other — that was the
   original bug).

## Field notes (append as you learn)

- **2026-06-01** — Baseline 25%. Diagnosed and fixed the split-brain: V1410-1 is now the sole
  server; `claudebox-client.sh` converts claudebox to a version-matched (2.0.2) client that
  `retry_join`s the server. claudebox is reachable on the LAN but tailnet-down; windesk is on
  the mesh but has no Nomad client; mac-mini is asleep with no WoL path. Connectivity metric
  job deployed and sampling every 5 min.
