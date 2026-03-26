job "minio-storage" {
  datacenters = ["dc1"]
  type        = "service"

  constraint {
    attribute = "${meta.role}"
    value     = "storage"
  }

  group "minio" {
    count = 1

    volume "storage" {
      type      = "host"
      source    = "storage"
      read_only = false
    }

    network {
      port "api" {
        static = 9000
      }
      port "console" {
        static = 9001
      }
    }

    task "minio" {
      driver = "docker"

      config {
        image = "minio/minio:latest"
        ports = ["api", "console"]
        args  = ["server", "/data", "--console-address", ":9001"]
      }

      volume_mount {
        volume      = "storage"
        destination = "/data"
        read_only   = false
      }

      # Credentials loaded from Nomad variables (encrypted at rest).
      # Set once: nomad var put nomad/jobs/minio-storage MINIO_ROOT_USER=monad-admin MINIO_ROOT_PASSWORD=<secret>
      template {
        data        = <<-EOT
{{ with nomadVar "nomad/jobs/minio-storage" }}
MINIO_ROOT_USER={{ .MINIO_ROOT_USER }}
MINIO_ROOT_PASSWORD={{ .MINIO_ROOT_PASSWORD }}
{{ end }}
EOT
        destination = "secrets/minio.env"
        env         = true
      }

      resources {
        cpu    = 500
        memory = 512
      }

      service {
        name     = "minio-api"
        port     = "api"
        provider = "nomad"

        check {
          type     = "http"
          path     = "/minio/health/live"
          port     = "api"
          interval = "30s"
          timeout  = "5s"
        }
      }

      service {
        name     = "minio-console"
        port     = "console"
        provider = "nomad"

        tags = [
          "traefik.enable=true",
          "traefik.http.routers.minio.rule=PathPrefix(`/minio`)",
        ]

        check {
          type     = "http"
          path     = "/"
          port     = "console"
          interval = "30s"
          timeout  = "5s"
        }
      }
    }
  }
}
