job "account-manager" {
  datacenters = ["dc1"]
  type        = "system"

  # Linux nodes — clone monad repo to get the script, then run it
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
        command = "/bin/bash"
        args    = ["-c", <<EOT
# Try local repo first, fall back to downloading
SCRIPT=""
for p in /home/bigo/Documents/monad /home/e/monad /root/monad; do
  [ -f "$p/scripts/account-manager.py" ] && SCRIPT="$p/scripts/account-manager.py" && break
done
if [ -z "$SCRIPT" ]; then
  mkdir -p /tmp/monad-am
  curl -sL https://raw.githubusercontent.com/claude-monad/monad/main/scripts/account-manager.py -o /tmp/monad-am/account-manager.py
  SCRIPT="/tmp/monad-am/account-manager.py"
fi
exec python3 "$SCRIPT"
EOT
        ]
      }

      env {
        ACCOUNT_MANAGER_PORT = "${NOMAD_PORT_http}"
        NOMAD_ADDR           = "http://100.78.218.70:4646"
        HOME                 = "/root"
      }

      resources {
        cpu    = 50
        memory = 64
      }
    }
  }

  # Windows nodes — use local path (windesk has the repo cloned)
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
