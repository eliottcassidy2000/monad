job "vault" {
  datacenters = ["dc1"]
  type        = "service"

  constraint {
    attribute = "${meta.role}"
    value     = "server"
  }

  update {
    max_parallel     = 1
    min_healthy_time = "15s"
    healthy_deadline = "3m"
    auto_revert      = true
  }

  group "vault" {
    count = 1

    volume "vault-data" {
      type      = "host"
      source    = "vault-data"
      read_only = false
    }

    restart {
      attempts = 10
      interval = "10m"
      delay    = "10s"
      mode     = "delay"
    }

    network {
      port "vault" {
        static = 8200
      }
    }

    # ── Main Vault server ─────────────────────────────────────────────
    task "vault" {
      driver = "docker"

      config {
        image   = "hashicorp/vault:1.15"
        ports   = ["vault"]
        command = "vault"
        args    = ["server", "-config=/local/vault-config.hcl"]
      }

      volume_mount {
        volume      = "vault-data"
        destination = "/vault/file"
        read_only   = false
      }

      template {
        data = <<-EOT
storage "file" {
  path = "/vault/file"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = 1
}

ui            = true
disable_mlock = true
api_addr      = "http://{{ env "NOMAD_IP_vault" }}:8200"
EOT
        destination = "local/vault-config.hcl"
      }

      env {
        VAULT_ADDR = "http://127.0.0.1:8200"
      }

      resources {
        cpu    = 500
        memory = 512
      }

      service {
        name     = "vault"
        port     = "vault"
        provider = "nomad"

        tags = [
          "traefik.enable=true",
          "traefik.http.routers.vault.rule=PathPrefix(`/ui/vault`)",
        ]

        check {
          type     = "http"
          path     = "/v1/sys/health?standbyok=true&sealedcode=200&uninitcode=200"
          port     = "vault"
          interval = "10s"
          timeout  = "3s"
        }
      }
    }

    # ── Init + unseal (raw_exec using curl against Vault HTTP API) ────
    task "init" {
      driver = "raw_exec"

      lifecycle {
        hook    = "poststart"
        sidecar = false
      }

      config {
        command = "/bin/bash"
        args    = ["local/init.sh"]
      }

      template {
        data = <<-SCRIPT
#!/bin/bash
set -e
VAULT_ADDR="http://{{ env "NOMAD_HOST_IP_vault" }}:{{ env "NOMAD_HOST_PORT_vault" }}"
KEYS_FILE="/opt/vault/data/.vault-keys.json"

echo "[vault-init] VAULT_ADDR=$VAULT_ADDR"
echo "[vault-init] Waiting for Vault API..."
for i in $(seq 1 60); do
  if curl -sf "$VAULT_ADDR/v1/sys/health?sealedcode=200&uninitcode=200" >/dev/null 2>&1; then
    echo "[vault-init] Vault reachable after ${i}s"
    break
  fi
  sleep 1
done

HEALTH=$(curl -sf "$VAULT_ADDR/v1/sys/health?sealedcode=200&uninitcode=200" 2>/dev/null) || {
  echo "[vault-init] Vault unreachable after 60s"; exit 1
}

INITIALIZED=$(echo "$HEALTH" | python3 -c "import sys,json; print(json.load(sys.stdin)['initialized'])")
SEALED=$(echo "$HEALTH" | python3 -c "import sys,json; print(json.load(sys.stdin)['sealed'])")

echo "[vault-init] initialized=$INITIALIZED sealed=$SEALED"

# Initialize if fresh
if [ "$INITIALIZED" = "False" ]; then
  echo "[vault-init] Initializing (1 key share, 1 threshold)..."
  INIT_RESP=$(curl -sf -X PUT "$VAULT_ADDR/v1/sys/init" \
    -H "Content-Type: application/json" \
    -d '{"secret_shares":1,"secret_threshold":1}')
  echo "$INIT_RESP" > "$KEYS_FILE"
  chmod 600 "$KEYS_FILE"
  echo "[vault-init] Keys written to $KEYS_FILE"
  SEALED="True"
fi

# Unseal if needed
if [ "$SEALED" = "True" ]; then
  if [ ! -f "$KEYS_FILE" ]; then
    echo "[vault-init] ERROR: sealed but no keys file"; exit 1
  fi
  UNSEAL_KEY=$(python3 -c "import json; print(json.load(open('$KEYS_FILE'))['keys_base64'][0])")
  echo "[vault-init] Unsealing..."
  curl -sf -X PUT "$VAULT_ADDR/v1/sys/unseal" \
    -H "Content-Type: application/json" \
    -d "{\"key\":\"$UNSEAL_KEY\"}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'  sealed={d[\"sealed\"]}')"
fi

# Get root token
ROOT_TOKEN=$(python3 -c "import json; print(json.load(open('$KEYS_FILE'))['root_token'])")

# Enable KV v2 at secret/ if not already
MOUNTS=$(curl -sf -H "X-Vault-Token: $ROOT_TOKEN" "$VAULT_ADDR/v1/sys/mounts" 2>/dev/null || echo '{}')
if ! echo "$MOUNTS" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if 'secret/' in d else 1)" 2>/dev/null; then
  echo "[vault-init] Enabling KV v2 at secret/..."
  curl -sf -X POST "$VAULT_ADDR/v1/sys/mounts/secret" \
    -H "X-Vault-Token: $ROOT_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"type":"kv","options":{"version":"2"}}'
fi

# Write worker policy
echo "[vault-init] Writing policies..."
curl -sf -X PUT "$VAULT_ADDR/v1/sys/policies/acl/monad-worker" \
  -H "X-Vault-Token: $ROOT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"policy":"path \"secret/data/claude-tokens/*\" { capabilities = [\"read\"] }\npath \"auth/token/revoke-self\" { capabilities = [\"update\"] }"}'

# Write dispatcher policy
curl -sf -X PUT "$VAULT_ADDR/v1/sys/policies/acl/monad-dispatcher" \
  -H "X-Vault-Token: $ROOT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"policy":"path \"secret/data/claude-tokens/*\" { capabilities = [\"read\", \"list\"] }\npath \"secret/metadata/claude-tokens/*\" { capabilities = [\"read\", \"list\"] }\npath \"secret/data/claude-tokens\" { capabilities = [\"read\", \"list\"] }\npath \"secret/metadata/claude-tokens\" { capabilities = [\"read\", \"list\"] }\npath \"auth/token/create\" { capabilities = [\"create\", \"update\"] }"}'

echo "[vault-init] Setup complete. Vault is ready."
SCRIPT
        destination = "local/init.sh"
      }

      resources {
        cpu    = 200
        memory = 128
      }
    }

    # ── Unsealer sidecar (raw_exec, checks every 15s) ────────────────
    task "unsealer" {
      driver = "raw_exec"

      lifecycle {
        hook    = "poststart"
        sidecar = true
      }

      config {
        command = "/bin/bash"
        args    = ["local/unsealer.sh"]
      }

      template {
        data = <<-SCRIPT
#!/bin/bash
VAULT_ADDR="http://{{ env "NOMAD_HOST_IP_vault" }}:{{ env "NOMAD_HOST_PORT_vault" }}"
KEYS_FILE="/opt/vault/data/.vault-keys.json"
echo "[vault-unsealer] Seal monitor started (15s interval, addr=$VAULT_ADDR)"

while true; do
  sleep 15
  HEALTH=$(curl -sf "$VAULT_ADDR/v1/sys/health?sealedcode=200&uninitcode=200" 2>/dev/null) || continue
  SEALED=$(echo "$HEALTH" | python3 -c "import sys,json; print(json.load(sys.stdin)['sealed'])" 2>/dev/null) || continue

  if [ "$SEALED" = "True" ]; then
    [ ! -f "$KEYS_FILE" ] && { echo "[vault-unsealer] No keys file"; continue; }
    UNSEAL_KEY=$(python3 -c "import json; print(json.load(open('$KEYS_FILE'))['keys_base64'][0])")
    echo "[vault-unsealer] Detected seal — unsealing..."
    curl -sf -X PUT "$VAULT_ADDR/v1/sys/unseal" \
      -H "Content-Type: application/json" \
      -d "{\"key\":\"$UNSEAL_KEY\"}" >/dev/null 2>&1 && echo "[vault-unsealer] Unsealed."
  fi
done
SCRIPT
        destination = "local/unsealer.sh"
      }

      resources {
        cpu    = 50
        memory = 64
      }
    }
  }
}
