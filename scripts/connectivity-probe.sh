#!/usr/bin/env bash
# connectivity-probe.sh — measure full-cluster connectivity & uptime, the Nomad-native way.
#
# THE SHARED GOAL (see MISSION.md): every roster machine simultaneously (a) on the Tailscale
# mesh AND (b) registered + `ready` as a Nomad node. This probe samples that state, appends to
# a git-tracked metrics CSV, computes rolling uptime per node, and emits a cluster event. Run
# it on the always-on server (V1410-1) on a schedule via jobs/cluster-connectivity.hcl, or by
# hand from any node: `scripts/connectivity-probe.sh`.
#
# A node counts as CONNECTED only when both signals are true — a machine can be on the LAN or
# even on the tailnet yet not be a working cluster node (e.g. windesk has no Nomad client;
# claudebox's tailnet link is down). The metric captures exactly that gap.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
METRICS_DIR="$REPO/logs/metrics"
CSV="$METRICS_DIR/connectivity.csv"
SNAP="$METRICS_DIR/connectivity-latest.json"
EVENTS="$REPO/logs/events.jsonl"
export NOMAD_ADDR="${NOMAD_ADDR:-http://100.75.75.39:4646}"
export PATH="$PATH:/usr/bin:/usr/local/bin:$HOME/bin"

mkdir -p "$METRICS_DIR"
[ -f "$CSV" ] || echo "epoch,node,tailnet_online,nomad_ready,connected" > "$CSV"

# Roster: the machines that make up "full connectivity". name<TAB>tailscale_ip
# Agents: add your machine here (and commit) so it's counted toward the cluster uptime metric.
ROSTER=$(cat <<'EOF'
V1410-1	100.75.75.39
claudebox	100.87.219.108
eliotts-mac-mini	100.113.252.45
windesk	100.94.210.54
EOF
)

TS_JSON="$(tailscale status --json 2>/dev/null || echo '{}')"
NODE_STATUS="$(nomad node status 2>/dev/null || true)"

EPOCH="${PROBE_EPOCH:-$(cat /proc/uptime >/dev/null 2>&1; date +%s 2>/dev/null || echo 0)}"

# Hand everything to python3 for JSON parsing + uptime math; it writes CSV rows, snapshot, event.
EPOCH="$EPOCH" CSV="$CSV" SNAP="$SNAP" EVENTS="$EVENTS" ROSTER="$ROSTER" \
NODE_STATUS="$NODE_STATUS" python3 - "$TS_JSON" <<'PY'
import json, os, sys, io

ts = {}
try:
    d = json.loads(sys.argv[1])
    peers = list(d.get("Peer", {}).values()) + ([d["Self"]] if "Self" in d else [])
    for p in peers:
        name = (p.get("HostName") or "").strip()
        if name:
            ts[name.lower()] = bool(p.get("Online"))
except Exception:
    pass

ready = set()
for line in os.environ.get("NODE_STATUS", "").splitlines():
    parts = line.split()
    # columns: ID Pool DC Name Class Drain Eligibility Status
    if len(parts) >= 8 and parts[-1] == "ready":
        ready.add(parts[3].lower())

roster = []
for ln in os.environ["ROSTER"].strip().splitlines():
    name, ip = ln.split("\t")
    roster.append((name, ip))

epoch = os.environ["EPOCH"]
csv_path, snap_path, ev_path = os.environ["CSV"], os.environ["SNAP"], os.environ["EVENTS"]

rows, connected_now = [], 0
snap_nodes = {}
for name, ip in roster:
    k = name.lower()
    online = 1 if ts.get(k) else 0
    nready = 1 if k in ready else 0
    conn = 1 if (online and nready) else 0
    connected_now += conn
    rows.append(f"{epoch},{name},{online},{nready},{conn}")
    snap_nodes[name] = {"tailscale_ip": ip, "tailnet_online": bool(online),
                        "nomad_ready": bool(nready), "connected": bool(conn)}

with open(csv_path, "a") as f:
    f.write("\n".join(rows) + "\n")

# Rolling uptime per node from the full CSV (fraction of samples where connected==1).
samples = {}
try:
    with open(csv_path) as f:
        next(f, None)
        for ln in f:
            p = ln.strip().split(",")
            if len(p) == 5:
                samples.setdefault(p[1], []).append(p[4] == "1")
except Exception:
    pass
for name in snap_nodes:
    s = samples.get(name, [])
    snap_nodes[name]["uptime_pct"] = round(100.0 * sum(s) / len(s), 1) if s else 0.0
    snap_nodes[name]["samples"] = len(s)

total = len(roster)
score = round(100.0 * connected_now / total, 1) if total else 0.0
snapshot = {"epoch": int(epoch) if str(epoch).isdigit() else epoch,
            "connected": connected_now, "expected": total,
            "connectivity_score_pct": score, "nodes": snap_nodes}
with open(snap_path, "w") as f:
    json.dump(snapshot, f, indent=2)

# Emit a cluster event matching the events.jsonl schema.
import datetime
iso = "epoch:" + str(epoch)
ev = {"ts": iso, "node": "V1410-1", "source": "connectivity",
      "action": "probe",
      "result": "full" if connected_now == total else ("partial" if connected_now else "down"),
      "detail": f"{connected_now}/{total} connected ({score}%); " +
                ", ".join(f"{n}={'up' if v['connected'] else ('mesh' if v['tailnet_online'] else 'off')}"
                          for n, v in snap_nodes.items())}
with open(ev_path, "a") as f:
    f.write(json.dumps(ev) + "\n")

# Human-readable summary (shows up in `nomad alloc-logs`).
print(f"cluster connectivity: {connected_now}/{total} = {score}%")
print(f"{'NODE':18} {'TAILNET':8} {'NOMAD':7} {'CONNECTED':10} {'UPTIME':7}")
for n, v in snap_nodes.items():
    print(f"{n:18} {'online' if v['tailnet_online'] else 'offline':8} "
          f"{'ready' if v['nomad_ready'] else '-':7} "
          f"{'YES' if v['connected'] else 'no':10} {v['uptime_pct']}%")
PY
