#!/usr/bin/env bash
# net-diag.sh — cluster networking investigation probe.
#
# THE INVESTIGATION (see NETWORKING.md): V1410-1 is the home router (LAN gateway
# 192.168.51.1, eno3) but it is NOT delivering usable internet to LAN machines, which have
# failed over to a backup-ISP wifi. Diagnosis so far: the router forwards ICMP + small TCP
# fine, but multi-packet TCP (TLS handshakes, downloads) black-holes — the far server stops
# receiving client->server data after the first segment. Ruled out: NAT config, MTU/MSS
# (clamp verified, no effect), NIC offloads. Suspected: the double-NAT WAN (eno0 is behind a
# private 192.168.225.1) or a conntrack/NAT interaction.
#
# Each node runs this from ITS OWN vantage point — especially valuable when a node is wired
# through V1410 (gateway 192.168.51.1) rather than on backup wifi, because that DEFINITIVELY
# tests the production forward path I could only approximate with a netns on the router.
#
# Usage: net-diag.sh [--loop SECONDS]   (one-shot by default)
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
[ -d "$REPO/.git" ] || REPO="${MONAD_REPO_DIR:-$HOME/monad}"
OUT_DIR="$REPO/logs/metrics"; mkdir -p "$OUT_DIR"
HOST="$(hostname)"
SNAP="$OUT_DIR/net-diag-$HOST.json"
EVENTS="$REPO/logs/events.jsonl"
export PATH="$PATH:/usr/sbin:/sbin:/usr/bin"

probe() {
  local gw small_ok large_ok ping_ok pmtu hop
  gw="$(ip route show default 2>/dev/null | awk '/default/{print $3; exit}')"
  ping_ok=no; ping -c1 -W2 8.8.8.8 >/dev/null 2>&1 && ping_ok=yes
  # small TCP (single-packet response) vs large TCP (multi-packet) — the key discriminator.
  small_ok=no
  curl -sS -m6 -o /dev/null "http://1.1.1.1/" >/dev/null 2>&1 && small_ok=yes
  large_ok=no; local dl
  dl="$(curl -4 -sS -m20 -o /dev/null -w '%{size_download}' 'https://speed.cloudflare.com/__down?bytes=1000000' 2>/dev/null || echo 0)"
  [ "${dl:-0}" -ge 1000000 ] 2>/dev/null && large_ok=yes
  # IPv6 large-TCP — the reliable path on this network (T-Mobile IPv4 intermittently black-holes
  # large TCP; native IPv6 does not). LAN clients get IPv6 via SLAAC from V1410 (fd00:51::/64).
  local large6_ok=no dl6
  dl6="$(curl -6 -sS -m20 -o /dev/null -w '%{size_download}' 'https://speed.cloudflare.com/__down?bytes=1000000' 2>/dev/null || echo 0)"
  [ "${dl6:-0}" -ge 1000000 ] 2>/dev/null && large6_ok=yes
  # path MTU (largest DF packet that egresses)
  pmtu=0; for s in 1472 1452 1432 1412 1392 1372 1352 1240; do
    if ping -M do -s "$s" -c1 -W2 8.8.8.8 >/dev/null 2>&1; then pmtu=$((s+28)); break; fi
  done
  hop="$(traceroute -n -m3 -w2 1.1.1.1 2>/dev/null | awk 'NR>1{print $2}' | paste -sd, - 2>/dev/null)"

  local via_v1410=no; [ "$gw" = "192.168.51.1" ] && via_v1410=yes
  local verdict="ok"
  if [ "$large_ok" = no ] && [ "$large6_ok" = yes ]; then verdict="ipv4_blackhole_ipv6_ok"
  elif [ "$small_ok" = yes ] && [ "$large_ok" = no ]; then verdict="BLACK_HOLE_large_tcp"
  elif [ "$ping_ok" = no ]; then verdict="no_route"
  elif [ "$large_ok" = yes ]; then verdict="ok"; else verdict="degraded"; fi

  cat > "$SNAP" <<EOF
{"host":"$HOST","gateway":"$gw","routing_via_v1410":$([ $via_v1410 = yes ] && echo true || echo false),
 "ping_8888":"$ping_ok","small_tcp":"$small_ok","large_tcp_1mb":"$large_ok","large_tcp_ipv6":"$large6_ok",
 "path_mtu":$pmtu,"first_hops":"${hop:-}","verdict":"$verdict"}
EOF
  echo "{\"ts\":\"probe\",\"node\":\"$HOST\",\"source\":\"net-diag\",\"action\":\"probe\",\"result\":\"$verdict\",\"detail\":\"gw=$gw via_v1410=$via_v1410 ping=$ping_ok small=$small_ok large_v4=$large_ok large_v6=$large6_ok pmtu=$pmtu\"}" >> "$EVENTS"
  echo "[net-diag] $HOST: verdict=$verdict gw=$gw via_v1410=$via_v1410 ping=$ping_ok small_tcp=$small_ok large_tcp_v4=$large_ok large_tcp_v6=$large6_ok pmtu=$pmtu"
  [ -n "${hop:-}" ] && echo "[net-diag] first hops: $hop"
}

if [ "${1:-}" = "--loop" ]; then
  iv="${2:-600}"; while true; do probe; sleep "$iv"; done
else
  probe
fi
