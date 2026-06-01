#!/usr/bin/env bash
# claudebox-server.sh — DEPRECATED shim.
#
# claudebox is no longer a cluster server. The control plane lives permanently on V1410-1
# (the always-on home-network router, 100.75.75.39); claudebox joins it as a CLIENT.
# Running two bootstrap_expect=1 servers with no join link created two separate clusters
# that could never communicate — that is the bug this corrects.
#
# This shim forwards to claudebox-client.sh so any existing @reboot/keepalive cron entry
# that still references "claudebox-server.sh" keeps working. Update your crontab to call
# claudebox-client.sh directly when convenient.
set -uo pipefail
echo "[claudebox-server] deprecated — claudebox is a CLIENT now; forwarding to claudebox-client.sh" >&2
exec "$(dirname "$0")/claudebox-client.sh" "$@"
