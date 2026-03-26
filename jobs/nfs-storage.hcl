job "nfs-storage" {
  datacenters = ["dc1"]
  type        = "service"

  constraint {
    attribute = "${meta.role}"
    value     = "storage"
  }

  group "nfs" {
    count = 1

    volume "storage" {
      type      = "host"
      source    = "storage"
      read_only = false
    }

    network {
      port "nfs" {
        static = 2049
      }
      port "mountd" {
        static = 20048
      }
      port "rpcbind" {
        static = 111
      }
    }

    task "nfs-server" {
      driver = "docker"

      config {
        image        = "itsthenetwork/nfs-server-alpine:latest"
        network_mode = "host"
        privileged   = true

        mount {
          type     = "bind"
          source   = "/srv/samba/public"
          target   = "/nfsshare"
          readonly = false
        }
      }

      env {
        SHARED_DIRECTORY = "/nfsshare"
        PERMITTED        = "100.64.0.0/10"
        SYNC             = "true"
        READ_ONLY        = "false"
      }

      resources {
        cpu    = 200
        memory = 256
      }

      service {
        name     = "nfs-storage"
        port     = "nfs"
        provider = "nomad"

        check {
          type     = "tcp"
          port     = "nfs"
          interval = "30s"
          timeout  = "5s"
        }
      }
    }
  }
}
