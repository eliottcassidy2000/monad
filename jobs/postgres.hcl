job "postgres" {
  datacenters = ["dc1"]
  type        = "service"

  constraint {
    attribute = "${meta.role}"
    value     = "storage"
  }

  group "db" {
    count = 1

    volume "storage" {
      type      = "host"
      source    = "storage"
      read_only = false
    }

    network {
      port "db" {
        static = 5432
      }
    }

    task "postgres" {
      driver = "docker"

      config {
        image = "postgres:16-alpine"
        ports = ["db"]
      }

      volume_mount {
        volume      = "storage"
        destination = "/data"
        read_only   = false
      }

      env {
        PGDATA = "/data/postgres/16/data"
      }

      template {
        data        = <<-EOT
{{ with nomadVar "nomad/jobs/postgres" }}
POSTGRES_USER={{ .POSTGRES_USER }}
POSTGRES_PASSWORD={{ .POSTGRES_PASSWORD }}
POSTGRES_DB={{ .POSTGRES_DB }}
{{ end }}
EOT
        destination = "secrets/postgres.env"
        env         = true
      }

      resources {
        cpu    = 500
        memory = 1024
      }

      service {
        name     = "postgres"
        port     = "db"
        provider = "nomad"

        check {
          type     = "tcp"
          port     = "db"
          interval = "10s"
          timeout  = "2s"
        }
      }
    }
  }
}
