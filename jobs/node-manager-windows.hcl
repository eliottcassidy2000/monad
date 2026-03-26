job "node-manager-windows" {
  datacenters = ["dc1"]
  type        = "system"

  constraint {
    attribute = "${attr.kernel.name}"
    value     = "windows"
  }

  group "manager" {
    task "sysadmin" {
      driver = "raw_exec"

      template {
        destination = "local/manage.ps1"
        data        = <<-SCRIPT
          function Log($msg) {
            $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            Write-Output "[node-manager $env:COMPUTERNAME $ts] $msg"
          }

          function Manage-Cycle {
            Log "=== Starting management cycle ==="

            # --- 1. Windows Update check ---
            Log "Checking Windows Update status..."
            try {
              $updates = Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 3
              foreach ($u in $updates) {
                Log ("  Last patch: {0} ({1})" -f $u.HotFixID, $u.InstalledOn)
              }
            } catch {
              Log "  WARN: Could not query hotfixes"
            }

            # --- 2. Service health ---
            Log "Checking critical services..."
            $services = @("Nomad", "Tailscale", "WinRM")
            foreach ($svc in $services) {
              $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
              if ($null -eq $s) {
                Log "  - ${svc}: not installed"
              } elseif ($s.Status -eq "Running") {
                Log "  OK ${svc}: Running"
              } else {
                Log "  WARN ${svc}: $($s.Status) - attempting restart"
                try { Restart-Service $svc -Force } catch { Log "  ERROR: restart failed" }
              }
            }

            # --- 3. Disk space ---
            Log "Disk space:"
            Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Used -gt 0 } | ForEach-Object {
              $total = [math]::Round(($_.Used + $_.Free) / 1GB, 1)
              $free = [math]::Round($_.Free / 1GB, 1)
              $pct = [math]::Round($_.Used / ($_.Used + $_.Free) * 100, 1)
              Log ("  {0}: {1}GB free / {2}GB total ({3}% used)" -f $_.Root, $free, $total, $pct)

              if ($pct -gt 85) {
                Log "  WARNING: Drive $($_.Root) above 85%!"
                Log "  Cleaning temp files..."
                Remove-Item "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue
              }
            }

            # --- 4. Memory and uptime ---
            $os = Get-CimInstance Win32_OperatingSystem
            $totalMem = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
            $freeMem = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
            Log "Memory: ${freeMem}GB free / ${totalMem}GB total"

            $uptime = (Get-Date) - $os.LastBootUpTime
            Log "Uptime: $([math]::Floor($uptime.TotalDays))d $($uptime.Hours)h $($uptime.Minutes)m"

            # --- 5. Network (Tailscale) ---
            try {
              $tsStatus = & tailscale status --json 2>$null | ConvertFrom-Json
              Log "Tailscale: $($tsStatus.BackendState)"
            } catch {
              Log "  WARN: Could not check Tailscale status"
            }

            Log "=== Management cycle complete ==="
          }

          Log "Windows node manager starting (10-minute cycle)"

          while ($true) {
            try { Manage-Cycle } catch { Log "ERROR: cycle failed: $_" }
            Log "Sleeping 600s..."
            Start-Sleep -Seconds 600
          }
        SCRIPT
      }

      config {
        command = "powershell.exe"
        args    = ["-ExecutionPolicy", "Bypass", "-File", "local/manage.ps1"]
      }

      resources {
        cpu    = 100
        memory = 256
      }
    }
  }
}
