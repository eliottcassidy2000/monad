#!/usr/bin/env bash
# Bootstrap a new node into the Monad cluster
# Usage: curl -sL <raw-url> | sudo bash -s -- [server|client] <server_ip>
set -euo pipefail

ROLE="${1:-client}"
SERVER_IP="${2:-100.78.218.70}"
NODE_NAME="$(hostname)"
TAILSCALE_IP="$(tailscale ip -4)"

echo "==> Setting up Monad node: $NODE_NAME ($TAILSCALE_IP) as $ROLE"
echo "==> Server: $SERVER_IP"

# Install Nomad if not present
if ! command -v nomad &>/dev/null; then
    echo "==> Installing Nomad..."
    curl -fsSL https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
        > /etc/apt/sources.list.d/hashicorp.list
    apt-get update -qq && apt-get install -y -qq nomad
fi

# Install Docker if not present
if ! command -v docker &>/dev/null; then
    echo "==> Installing Docker..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -qq && apt-get install -y -qq docker-ce docker-ce-cli containerd.io
fi

# Create data dir
mkdir -p /opt/nomad/data /etc/nomad.d

# Clone monad repo for the sync volume
MONAD_DIR="/home/bigo/Documents/monad"
if [ ! -d "$MONAD_DIR" ]; then
    mkdir -p "$(dirname "$MONAD_DIR")"
    git clone https://github.com/claude-monad/monad.git "$MONAD_DIR"
fi

# Write config
TEMPLATE="cluster/${ROLE}.hcl"
if [ -f "$MONAD_DIR/$TEMPLATE" ]; then
    sed -e "s/TAILSCALE_IP/$TAILSCALE_IP/g" \
        -e "s/NODE_NAME/$NODE_NAME/g" \
        -e "s/SERVER_IP/$SERVER_IP/g" \
        "$MONAD_DIR/$TEMPLATE" > /etc/nomad.d/nomad.hcl
    echo "==> Config written from template"
else
    echo "==> ERROR: Template $TEMPLATE not found"
    exit 1
fi

# Enable and start
systemctl enable nomad
systemctl restart nomad

echo "==> Waiting for Nomad to start..."
sleep 5

export NOMAD_ADDR="http://$TAILSCALE_IP:4646"
if nomad node status &>/dev/null; then
    echo "==> Node joined the cluster successfully!"
    nomad node status
else
    echo "==> Node started but may not have joined yet. Check: nomad node status"
fi
