job "monitoring" {
  datacenters = ["dc1"]
  type        = "service"

  constraint {
    attribute = "${meta.role}"
    value     = "server"
  }

  group "prometheus" {
    count = 1

    network {
      port "prometheus" {
        static = 9090
      }
    }

    task "prometheus" {
      driver = "docker"

      config {
        image   = "prom/prometheus:v2.51.0"
        ports   = ["prometheus"]
        args    = [
          "--config.file=/etc/prometheus/prometheus.yml",
          "--storage.tsdb.retention.time=7d",
          "--web.listen-address=:9090",
        ]
        volumes = [
          "local/prometheus.yml:/etc/prometheus/prometheus.yml",
        ]
      }

      template {
        data = <<-EOT
global:
  scrape_interval: 30s
  evaluation_interval: 30s

scrape_configs:
  - job_name: nomad-nodes
    metrics_path: /v1/metrics
    params:
      format: [prometheus]
    static_configs:
      - targets:
          - 100.78.218.70:4646
          - 100.96.31.66:4646
          - 100.119.217.63:4646
          - 100.75.75.39:4646
          - 100.94.210.54:4646
        labels:
          cluster: monad

  - job_name: prometheus
    static_configs:
      - targets:
          - localhost:9090
EOT
        destination = "local/prometheus.yml"
      }

      resources {
        cpu    = 300
        memory = 512
      }

      service {
        name     = "prometheus"
        port     = "prometheus"
        provider = "nomad"

        tags = [
          "traefik.enable=true",
          "traefik.http.routers.prometheus.rule=PathPrefix(`/prometheus`)",
        ]

        check {
          type     = "http"
          path     = "/-/healthy"
          port     = "prometheus"
          interval = "15s"
          timeout  = "5s"
        }
      }
    }
  }

  group "grafana" {
    count = 1

    network {
      port "grafana" {
        static = 3000
      }
    }

    task "grafana" {
      driver = "docker"

      config {
        image   = "grafana/grafana:11.0.0"
        ports   = ["grafana"]
        volumes = [
          "local/datasources.yml:/etc/grafana/provisioning/datasources/datasources.yml",
        ]
      }

      env {
        GF_SERVER_ROOT_URL          = "http://100.78.218.70:3000"
        GF_SECURITY_ALLOW_EMBEDDING = "true"
      }

      template {
        data        = <<-EOT
{{ with nomadVar "nomad/jobs/monitoring" }}
GF_SECURITY_ADMIN_PASSWORD={{ .GF_SECURITY_ADMIN_PASSWORD }}
{{ end }}
EOT
        destination = "secrets/grafana.env"
        env         = true
      }

      template {
        data = <<-EOT
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    url: http://100.78.218.70:9090
    access: proxy
    isDefault: true
    editable: true
EOT
        destination = "local/datasources.yml"
      }

      resources {
        cpu    = 200
        memory = 256
      }

      service {
        name     = "grafana"
        port     = "grafana"
        provider = "nomad"

        tags = [
          "traefik.enable=true",
          "traefik.http.routers.grafana.rule=PathPrefix(`/grafana`)",
        ]

        check {
          type     = "http"
          path     = "/api/health"
          port     = "grafana"
          interval = "15s"
          timeout  = "5s"
        }
      }
    }
  }
}
