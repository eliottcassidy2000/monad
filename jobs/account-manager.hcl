job "account-manager" {
  datacenters = ["dc1"]
  type        = "system"

  # Linux nodes
  group "linux" {
    constraint {
      attribute = "${attr.kernel.name}"
      value     = "linux"
    }

    network {
      port "http" {
        static = 7700
      }
    }

    service {
      name     = "account-manager"
      port     = "http"
      provider = "nomad"
    }

    task "server" {
      driver = "raw_exec"

      config {
        command = "python3"
        args    = ["/home/bigo/Documents/monad/scripts/account-manager.py"]
      }

      env {
        ACCOUNT_MANAGER_PORT = "${NOMAD_PORT_http}"
        NOMAD_ADDR           = "http://100.78.218.70:4646"
      }

      resources {
        cpu    = 50
        memory = 64
      }
    }
  }

  # Windows nodes
  group "windows" {
    constraint {
      attribute = "${attr.kernel.name}"
      value     = "windows"
    }

    network {
      port "http" {
        static = 7700
      }
    }

    service {
      name     = "account-manager"
      port     = "http"
      provider = "nomad"
    }

    task "server" {
      driver = "raw_exec"

      config {
        command = "python3"
        args    = ["C:\\Users\\Eliott\\monad\\scripts\\account-manager.py"]
      }

      env {
        ACCOUNT_MANAGER_PORT = "${NOMAD_PORT_http}"
        NOMAD_ADDR           = "http://100.78.218.70:4646"
      }

      resources {
        cpu    = 50
        memory = 64
      }
    }
  }
}
