job "claude-container-test" {
  datacenters = ["dc1"]
  type        = "batch"

  # Run on nodes with Claude credentials and the monad-claude Docker image
  constraint {
    attribute = "${meta.has_claude}"
    value     = "true"
  }

  group "claude-docker" {
    count = 1

    task "session" {
      driver = "docker"

      config {
        image      = "monad-claude:v1"
        entrypoint = ["bash"]
        args = ["-c", <<-EOT
          mkdir -p /home/claude/.claude
          cp /tmp/host-claude.json /home/claude/.claude.json
          cp /tmp/host-credentials.json /home/claude/.claude/.credentials.json
          exec claude -p --model haiku --allowedTools "" --dangerously-skip-permissions \
            "$CLAUDE_PROMPT"
        EOT
        ]

        volumes = [
          "/home/e/.claude.json:/tmp/host-claude.json:ro",
          "/home/e/.claude/.credentials.json:/tmp/host-credentials.json:ro"
        ]
      }

      env {
        CLAUDE_PROMPT = "You are a containerized Claude running inside a Nomad Docker job on the Monad cluster. Report your container ID, PID namespace, hostname, and current time. Confirm Docker isolation is working."
      }

      resources {
        cpu    = 200
        memory = 256
      }

      kill_timeout = "60s"
    }

    restart {
      attempts = 0
      mode     = "fail"
    }
  }
}
