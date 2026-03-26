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
        # disable_mlock set in config; IPC_LOCK not needed
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

    # ── Init + unseal (runs once after vault starts) ──────────────────
    task "init" {
      driver = "docker"

      lifecycle {
        hook    = "poststart"
        sidecar = false
      }

      config {
        image        = "hashicorp/vault:1.15"
        network_mode = "host"
        command      = "/bin/sh"
        args         = ["/local/init.sh"]
      }

      volume_mount {
        volume      = "vault-data"
        destination = "/vault/file"
        read_only   = false
      }

      template {
        data        = "VAULT_ADDR=http://{{ env \"NOMAD_HOST_IP_vault\" }}:{{ env \"NOMAD_HOST_PORT_vault\" }}"
        destination = "local/vault.env"
        env         = true
      }

      template {
        data = <<-SCRIPT
#!/bin/sh
set -e
KEYS_FILE="/vault/file/.vault-keys.json"

echo "[vault-init] VAULT_ADDR=$VAULT_ADDR"
echo "[vault-init] Waiting for Vault API..."
for i in $(seq 1 60); do
  if vault status -format=json >/dev/null 2>&1; then
    echo "[vault-init] Vault reachable after ${i}s"
    break
  fi
  sleep 1
done

STATUS=$(vault status -format=json 2>/dev/null) || { echo "[vault-init] Vault unreachable after 60s"; exit 1; }
INITIALIZED=$(echo "$STATUS" | sed -n 's/.*"initialized": *\(true\|false\).*/\1/p')
SEALED=$(echo "$STATUS" | sed -n 's/.*"sealed": *\(true\|false\).*/\1/p')

echo "[vault-init] initialized=$INITIALIZED sealed=$SEALED"

# Initialize if fresh
if [ "$INITIALIZED" = "false" ]; then
  echo "[vault-init] Initializing (1 key share, 1 threshold)..."
  vault operator init -key-shares=1 -key-threshold=1 -format=json > "$KEYS_FILE"
  chmod 600 "$KEYS_FILE"
  echo "[vault-init] Keys written to $KEYS_FILE"
  SEALED="true"
fi

# Unseal if needed
if [ "$SEALED" = "true" ]; then
  if [ ! -f "$KEYS_FILE" ]; then
    echo "[vault-init] ERROR: sealed but no keys file at $KEYS_FILE"
    exit 1
  fi
  UNSEAL_KEY=$(sed -n 's/.*"unseal_keys_b64":\["\([^"]*\)".*/\1/p' "$KEYS_FILE")
  echo "[vault-init] Unsealing..."
  vault operator unseal "$UNSEAL_KEY"
fi

# Authenticate with root token
ROOT_TOKEN=$(sed -n 's/.*"root_token":"\([^"]*\)".*/\1/p' "$KEYS_FILE")
export VAULT_TOKEN="$ROOT_TOKEN"

# Enable KV v2 at secret/
if ! vault secrets list -format=json 2>/dev/null | grep -q '"secret/"'; then
  echo "[vault-init] Enabling KV v2 at secret/..."
  vault secrets enable -version=2 -path=secret kv
fi

# Write worker policy (read tokens, revoke own token)
echo "[vault-init] Writing policies..."
vault policy write monad-worker - <<'POLICY'
path "secret/data/claude-tokens/*" {
  capabilities = ["read"]
}
path "auth/token/revoke-self" {
  capabilities = ["update"]
}
POLICY

# Write dispatcher policy (list/read tokens, create child tokens)
vault policy write monad-dispatcher - <<'POLICY'
path "secret/data/claude-tokens/*" {
  capabilities = ["read", "list"]
}
path "secret/metadata/claude-tokens/*" {
  capabilities = ["read", "list"]
}
path "secret/data/claude-tokens" {
  capabilities = ["read", "list"]
}
path "secret/metadata/claude-tokens" {
  capabilities = ["read", "list"]
}
path "auth/token/create" {
  capabilities = ["create", "update"]
}
POLICY

echo "[vault-init] Setup complete. Vault is ready."
SCRIPT
        destination = "local/init.sh"
      }

      resources {
        cpu    = 200
        memory = 128
      }
    }

    # ── Unsealer sidecar (auto-unseal on restart/reschedule) ──────────
    task "unsealer" {
      driver = "docker"

      lifecycle {
        hook    = "poststart"
        sidecar = true
      }

      config {
        image        = "hashicorp/vault:1.15"
        network_mode = "host"
        command      = "/bin/sh"
        args         = ["/local/unsealer.sh"]
      }

      volume_mount {
        volume      = "vault-data"
        destination = "/vault/file"
        read_only   = true
      }

      template {
        data        = "VAULT_ADDR=http://{{ env \"NOMAD_HOST_IP_vault\" }}:{{ env \"NOMAD_HOST_PORT_vault\" }}"
        destination = "local/vault-unsealer.env"
        env         = true
      }

      template {
        data = <<-SCRIPT
#!/bin/sh
KEYS_FILE="/vault/file/.vault-keys.json"
echo "[vault-unsealer] Seal monitor started (15s interval, addr=$VAULT_ADDR)"

while true; do
  sleep 15
  STATUS=$(vault status -format=json 2>/dev/null) || continue
  SEALED=$(echo "$STATUS" | sed -n 's/.*"sealed": *\(true\|false\).*/\1/p')

  if [ "$SEALED" = "true" ]; then
    [ ! -f "$KEYS_FILE" ] && { echo "[vault-unsealer] No keys file"; continue; }
    UNSEAL_KEY=$(sed -n 's/.*"unseal_keys_b64":\["\([^"]*\)".*/\1/p' "$KEYS_FILE")
    echo "[vault-unsealer] Detected seal — unsealing..."
    vault operator unseal "$UNSEAL_KEY" >/dev/null 2>&1 && echo "[vault-unsealer] Unsealed."
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
