job "vault" {
  datacenters = ["dc1"]
  type        = "service"

  constraint {
    attribute = "${meta.role}"
    value     = "server"
  }

  group "vault" {
    count = 1

    volume "monad-repo" {
      type      = "host"
      source    = "monad-repo"
      read_only = false
    }

    network {
      port "vault" {
        static = 8200
      }
    }

    task "vault" {
      driver = "docker"

      config {
        image   = "hashicorp/vault:1.15"
        ports   = ["vault"]
        command = "vault"
        args    = ["server", "-config=/local/vault-config.hcl"]

        # disable_mlock is set in vault config since Docker driver
        # doesn't allow IPC_LOCK capability by default
      }

      volume_mount {
        volume      = "monad-repo"
        destination = "/vault/repo"
        read_only   = false
      }

      template {
        data = <<-EOT
storage "file" {
  path = "/vault/repo/.vault-data"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = 1
}

ui            = true
disable_mlock = true
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
          interval = "15s"
          timeout  = "5s"
        }
      }
    }
  }
}
