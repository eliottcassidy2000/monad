job "whoami" {
  datacenters = ["dc1"]
  type        = "service"

  group "web" {
    count = 1

    network {
      port "http" {
        to = 80
      }
    }

    service {
      name     = "whoami"
      port     = "http"
      provider = "nomad"

      tags = [
        "traefik.enable=true",
        "traefik.http.routers.whoami.rule=PathPrefix(`/whoami`)",
      ]
    }

    task "whoami" {
      driver = "docker"

      config {
        image = "traefik/whoami:latest"
        ports = ["http"]
      }

      resources {
        cpu    = 50
        memory = 32
      }
    }
  }
}
