job "claude-session" {
  datacenters = ["dc1"]
  type        = "batch"

  parameterized {
    meta_required = ["conversation_id", "turn"]
    meta_optional = ["model", "system_prompt"]
    payload       = "required"
  }

  constraint {
    attribute = "${meta.has_claude}"
    value     = "true"
  }

  group "session" {
    count = 1

    task "claude" {
      driver = "docker"

      config {
        image      = "monad-claude:v2"
        entrypoint = ["bash"]
        args       = ["-c", "container-entrypoint.sh"]

        volumes = [
          "/home/e/.claude.json:/tmp/host-claude.json:ro",
          "/home/e/.claude/.credentials.json:/tmp/host-credentials.json:ro"
        ]
      }

      env {
        CLAUDE_MODEL = "haiku"
      }

      # The dispatch payload becomes the prompt via NOMAD_TASK_DIR/dispatch_payload
      dispatch_payload {
        file = "dispatch_payload"
      }

      resources {
        cpu    = 300
        memory = 512
      }

      kill_timeout = "120s"
    }

    restart {
      attempts = 1
      interval = "5m"
      delay    = "10s"
      mode     = "fail"
    }
  }
}
