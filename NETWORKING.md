# Cluster Investigation: Router Internet Path (LAN → WAN)

**Status: RESOLVED (2026-06-03) — native IPv4 fixed with an MSS clamp; no exit node needed.**
Tracked by the `net-diag` Nomad system job and linked from [MISSION.md](./MISSION.md).

## Resolution: native IPv4 via MSS clamp (the real "HTTP works, HTTPS doesn't" fix)

The decisive clue was **HTTP works but HTTPS hangs** (ping + basic curl fine, no web pages).
That is the textbook signature of an **MTU / PMTUD black hole**, not a dead uplink:

- The T-Mobile WAN (`eno0`) MTU is **1472**; LAN clients are **1500** (and storage boxes like
  `death-star` may use **9000** jumbo frames).
- A 1500-MTU client advertises **MSS 1460**, so servers send 1500-byte packets. The small TLS
  ClientHello/HTTP request gets through, but the **multi-packet TLS certificate** overflows the
  1472 WAN and is **dropped upstream with no ICMP "frag-needed"** → PMTUD never kicks in → the
  handshake stalls. HTTP (tiny responses) survives; HTTPS dies.
- The router's *own* traffic works because it already uses MSS 1432 (its 1472 MTU).

**Fix (V1410-1, persisted + reboot-safe in `/etc/nftables.conf`):** a dedicated
`table inet monad_mss` with a `forward` hook clamps every forwarded TCP SYN's MSS to the egress
route MTU. Verified on the wire: a client's `mss 1460` leaves `eno0` rewritten to **`mss 1432`**,
so server packets fit the whole path. This is independent of PMTUD and works for any client MTU
(including jumbo). HTTPS now works **natively** for LAN clients — IPv4 and IPv6 both carry 1 MB
downloads from the router and from a forwarded client.

**The oraclebox1 exit node is no longer used** (it was a stop-gap that routed everything through
Chicago). It remains available as a manual fallback (`tailscale set --exit-node=oraclebox1`), but
the default is the native path. The earlier exit-node scaffolding (tailscale0 SNAT, the v6-native
ip rule + systemd unit) has been removed. The IPv6 setup below is unchanged and still native.

---

### Earlier mitigation (still in place): native IPv6 to the LAN

## Resolution: native-style IPv6 to the LAN (bypasses the broken IPv4 path)

The IPv4 fault turned out to be **intermittent and upstream**: at times the T-Mobile path
**black-holes large TCP even for V1410's own traffic** (small HTTP/ping work, 1 MB download
times out) — measured directly: IPv4 `1MB → 0 bytes` while **IPv6 `1MB → 0.46 s` at the same
instant**. The WAN is a T-Mobile 5G gateway (double-NAT/CGNAT) and can't be bridged. **IPv6 is
T-Mobile-native (no NAT, no CGNAT) and reliably carries large TCP**, so the LAN now rides IPv6.

What was deployed on V1410-1 (all persisted, reboot-safe):
- **IPv6 forwarding** on, with `net.ipv6.conf.eno0.accept_ra=2` so eno0 keeps T-Mobile's RA
  address+route while routing (`/etc/sysctl.d/99-ipv6-router.conf`).
- **dnsmasq RA** on eno3 advertising **`fd00:51::/64`** (SLAAC) + IPv6 DNS
  (`/etc/dnsmasq.d/ipv6-lan.conf`); eno3 gateway `fd00:51::1` (stored in NetworkManager).
- **NAT66**: `table ip6 monad_nat` masquerades `fd00:51::/64` out eno0 to eno0's current global
  address (`/etc/nftables.conf`).

**Why ULA + NAT66 instead of a global prefix:** T-Mobile gives **no prefix delegation** and is
**rotating prefixes** (eno0 went from one `2607:fb90:6d1a:108::/64` to three /64s in a day, the
original deprecating). A hardcoded native prefix would break on rotation; the ULA is stable and
the masquerade auto-tracks whatever global eno0 holds. Dual-stack sites (Google, Cloudflare, …)
will now **prefer the reliable IPv6 path** (RFC 6724 / Happy Eyeballs); IPv4-only destinations
still traverse the flaky IPv4 path.

**For nodes:** when wired through V1410, `net-diag` now reports `large_tcp_ipv6`. A verdict of
`ipv4_blackhole_ipv6_ok` is the expected state and confirms the IPv6 path is doing its job.
Remaining open thread: whether T-Mobile's IPv4 can be made reliable at all (likely needs gateway
bridge mode, which this hardware lacks) — low priority now that IPv6 carries the load.

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
