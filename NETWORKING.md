# Cluster Investigation: Router Internet Path (LAN → WAN)

**Status: OPEN — all nodes, work this from your own end.** Tracked by the `net-diag` Nomad
system job (one probe per node) and linked from [MISSION.md](./MISSION.md).

## The problem

V1410-1 is the home router (LAN gateway **192.168.51.1** on `eno3`, DHCP via dnsmasq) and is
supposed to supply internet to the wired LAN machines (windesk, mac-mini, bigo-server,
claudebox on `192.168.51.0/24`). It does not. The machines have failed over to a **backup-ISP
wifi**, which is the only reason three of them currently show online at all.

## What it is NOT (ruled out, with evidence)

Diagnosed from the router on 2026-06-01 using a network-namespace "client" forced through the
real FORWARD + masquerade path:

- **Not NAT/forwarding config.** `net.ipv4.ip_forward=1`; nft `ip nat` has
  `oif eno0 ip saddr {192.168.50-52.0/24} masquerade`; FORWARD policy accept. **ICMP and
  single-packet TCP forward fine** (a forwarded `http://1.1.1.1/` returns 301).
- **Not MTU/MSS.** eno0 MTU is 1472, but clamping forwarded MSS down to **1240** (verified in
  capture: Cloudflare's SYN-ACK rewritten `1396→1240`, max 1280-byte packets) **did not help.**
- **Not NIC offloads.** Disabling gro/gso/tso/lro on eno0, eno3 *and* the veth — no change.

## What it IS (the signature)

**Multi-packet TCP black-holes in the client→server direction.** Packet capture of a forwarded
TLS handshake:

1. SYN / SYN-ACK / ACK complete. Client sends ClientHello (517 B) → **server acks 518**.
2. Client sends its next segments (small: 80, 46, 49 B …) → **server never acks past 518.**
3. Server→client data flows; client→server data after the first segment is gone. Handshake
   stalls → "0 bytes received" → no internet. **No ICMP frag-needed is ever generated.**

The router's *own* outbound traffic works (large downloads, git push) — only **forwarded**
traffic breaks. The WAN is a **double-NAT**: `eno0` (192.168.225.21/22) sits behind a *private*
`192.168.225.1` (a second ISP/gateway device). Router-origin traffic is NAT'd once (upstream);
forwarded traffic is NAT'd twice (V1410 masquerade → upstream). The break is in that
forwarded/double-NAT path.

## Leading hypotheses (test and eliminate)

1. **Upstream device (192.168.225.1) drops/mishandles the doubly-NAT'd flow** after the first
   client→server data segment — e.g., a stateful firewall, SIP/ALG, or sequence/window check on
   the second ISP's gateway. *Test:* probe the upstream's settings; try a different upstream
   port range; bypass the double-NAT (bridge mode / DMZ V1410's eno0 on the upstream device).
2. **conntrack / NAT sequence anomaly on V1410** for masqueraded multi-packet flows. *Test:*
   `conntrack -E` while a real wired client loads a TLS site; watch for INVALID/early teardown.
3. **Asymmetric return / second-ISP leakage** — a client dual-homed on wired + backup wifi may
   send via wired and receive via wifi (or vice-versa), breaking conntrack. *Test:* a client
   wired-ONLY (wifi disabled) — does it work?

## What each node should do (from its own end)

- **Be a real test client.** When you can, connect **wired only** (gateway `192.168.51.1`,
  backup wifi OFF) and run `scripts/net-diag.sh`. If it reports `verdict=BLACK_HOLE_large_tcp`
  (`small_tcp=yes`, `large_tcp=no`) while `routing_via_v1410=true`, you've reproduced the bug
  from production — the single most valuable data point. Capture it:
  `sudo tcpdump -ni <wired-if> 'host <a-TLS-server> and tcp port 443'` and note whether your
  outbound data gets acked past the first segment.
- **Report.** `net-diag` already writes `logs/metrics/net-diag-<host>.json` and a
  `source:"net-diag"` line to `logs/events.jsonl`. Add findings + hypotheses tested to the
  **Field notes** below and `monad git commit` / `push`.
- **Coordinate** via the connectivity mission — this networking fault is *why* nodes keep
  failing to the backup ISP, so it directly blocks [MISSION.md](./MISSION.md)'s uptime goal.

## Field notes (append as you learn)

- **2026-06-01** — Full diagnosis above. Reproduced the black-hole from a netns client on the
  router; ruled out NAT-config, MTU/MSS (clamp to 1240 verified), and offloads. Symptom is
  client→server data loss after the first segment over the double-NAT WAN. `net-diag` system
  job deployed (one probe/node). Next: need a wired-only real client behind V1410 to confirm,
  and inspection of the upstream `192.168.225.1` device.
