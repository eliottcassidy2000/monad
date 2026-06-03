#!/usr/bin/env bash
# install-watchers.sh — install/refresh the 3 ever-present Codex watcher quorum on this node.
# Idempotent: re-run to update the unit or pick up a new watcher.sh. See HEALTH.md.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
U="${SUDO_USER:-${USER:-e}}"

sudo install -m644 "$REPO/cluster/monad-watcher@.service" /etc/systemd/system/monad-watcher@.service

# Narrow sudoers: let the watcher user restart ONLY peer watcher units (for mutual supervision).
sudo tee /etc/sudoers.d/monad-watcher >/dev/null <<EOF
$U ALL=(root) NOPASSWD: /usr/bin/systemctl restart monad-watcher@*, /usr/bin/systemctl start monad-watcher@*, /usr/bin/systemctl stop monad-watcher@*, /usr/bin/systemctl is-active monad-watcher@*
EOF
sudo chmod 440 /etc/sudoers.d/monad-watcher
sudo visudo -cf /etc/sudoers.d/monad-watcher >/dev/null

sudo systemctl daemon-reload
for i in 1 2 3; do sudo systemctl enable --now "monad-watcher@$i.service"; done
echo -n "watcher quorum: "; for i in 1 2 3; do printf '%s=%s ' "$i" "$(systemctl is-active "monad-watcher@$i.service")"; done; echo
