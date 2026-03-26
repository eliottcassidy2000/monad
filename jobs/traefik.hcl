job "traefik" {
  datacenters = ["dc1"]
  type        = "service"

  constraint {
    attribute = "${meta.role}"
    value     = "server"
  }

  group "traefik" {
    count = 1

    network {
      port "http" {
        static = 80
      }
      port "dashboard" {
        static = 8081
      }
    }

    task "traefik" {
      driver = "docker"

      config {
        image = "traefik:v3.2"
        ports = ["http", "dashboard"]
        args  = [
          "--api.dashboard=true",
          "--api.insecure=true",
          "--entrypoints.web.address=:80",
          "--providers.nomad=true",
          "--providers.nomad.endpoint.address=http://100.78.218.70:4646",
          "--providers.nomad.exposedByDefault=false",
        ]
      }

      resources {
        cpu    = 200
        memory = 256
      }

      service {
        name     = "traefik-http"
        port     = "http"
        provider = "nomad"

        check {
          type     = "tcp"
          port     = "http"
          interval = "10s"
          timeout  = "2s"
        }
      }

      service {
        name     = "traefik-dashboard"
        port     = "dashboard"
        provider = "nomad"

        check {
          type     = "http"
          path     = "/dashboard/"
          port     = "dashboard"
          interval = "15s"
          timeout  = "5s"
        }
      }
    }
  }
}
