job "redis" {
  datacenters = ["dc1"]
  type        = "service"

  constraint {
    attribute = "${attr.kernel.name}"
    value     = "linux"
  }

  group "cache" {
    count = 1

    network {
      port "redis" {
        static = 6379
      }
    }

    task "redis" {
      driver = "docker"

      config {
        image = "redis:7-alpine"
        ports = ["redis"]
        args  = [
          "redis-server",
          "--save", "",
          "--appendonly", "no",
          "--maxmemory", "256mb",
          "--maxmemory-policy", "allkeys-lru",
          "--bind", "0.0.0.0",
          "--protected-mode", "no",
        ]
      }

      resources {
        cpu    = 200
        memory = 300
      }

      service {
        name     = "redis"
        port     = "redis"
        provider = "nomad"

        check {
          type     = "tcp"
          port     = "redis"
          interval = "10s"
          timeout  = "2s"
        }
      }
    }
  }
}
