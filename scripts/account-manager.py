#!/usr/bin/env python3
"""
Account Manager — web UI for managing Claude auth across the Monad cluster.

Serves on port 7700 (Tailnet-only). Deployed as a Nomad system job so every node
runs an instance. Each instance manages its own node's Claude auth, and the
dashboard aggregates status from all nodes.

Usage:
    python3 scripts/account-manager.py                    # start on port 7700
    python3 scripts/account-manager.py --port 8080        # custom port
"""

import http.server
import json
import subprocess
import threading
import urllib.request
import urllib.parse
import os
import sys
import socket
import time
import html
from pathlib import Path
from datetime import datetime

PORT = int(os.environ.get("ACCOUNT_MANAGER_PORT", "7700"))
NOMAD_ADDR = os.environ.get("NOMAD_ADDR", "http://100.78.218.70:4646")
NODE_NAME = socket.gethostname()

# Track active login processes
login_state = {"process": None, "url": None, "status": "idle", "error": None}
login_lock = threading.Lock()


# ─── Claude auth helpers ─────────────────────────────────────────────────────

def get_auth_status():
    """Get current Claude auth status as a dict."""
    try:
        result = subprocess.run(
            ["claude", "auth", "status"],
            capture_output=True, text=True, timeout=10,
            env={**os.environ, "HOME": os.environ.get("HOME", "/root")}
        )
        if result.returncode == 0:
            data = json.loads(result.stdout.strip())
            return {
                "node": NODE_NAME,
                "logged_in": data.get("loggedIn", False),
                "email": data.get("email", ""),
                "subscription": data.get("subscriptionType", "unknown"),
                "auth_method": data.get("authMethod", ""),
                "org": data.get("orgName", ""),
            }
        else:
            return {
                "node": NODE_NAME,
                "logged_in": False,
                "email": "",
                "subscription": "",
                "error": result.stderr.strip(),
            }
    except FileNotFoundError:
        return {"node": NODE_NAME, "logged_in": False, "error": "claude not installed"}
    except subprocess.TimeoutExpired:
        return {"node": NODE_NAME, "logged_in": False, "error": "timeout"}
    except json.JSONDecodeError as e:
        return {"node": NODE_NAME, "logged_in": False, "error": f"parse error: {e}"}
    except Exception as e:
        return {"node": NODE_NAME, "logged_in": False, "error": str(e)}


def do_logout():
    """Log out of Claude."""
    try:
        result = subprocess.run(
            ["claude", "auth", "logout"],
            capture_output=True, text=True, timeout=10,
            env={**os.environ, "HOME": os.environ.get("HOME", "/root")}
        )
        return {"ok": result.returncode == 0, "output": result.stdout + result.stderr}
    except Exception as e:
        return {"ok": False, "output": str(e)}


def start_login():
    """Start the Claude login flow and capture the OAuth URL."""
    global login_state
    with login_lock:
        if login_state["process"] is not None:
            return {"ok": False, "error": "Login already in progress"}
        login_state = {"process": True, "url": None, "status": "starting", "error": None}

    def _login_thread():
        global login_state
        try:
            proc = subprocess.Popen(
                ["claude", "auth", "login"],
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, bufsize=1
            )
            with login_lock:
                login_state["process"] = proc
                login_state["status"] = "waiting_for_url"

            full_output = []
            for line in proc.stdout:
                full_output.append(line)
                # Look for a URL in the output
                stripped = line.strip()
                if "http" in stripped:
                    # Extract URL — might be the whole line or embedded
                    for word in stripped.split():
                        if word.startswith("http"):
                            with login_lock:
                                login_state["url"] = word
                                login_state["status"] = "awaiting_browser"
                            break

            proc.wait(timeout=300)
            with login_lock:
                if proc.returncode == 0:
                    login_state["status"] = "complete"
                else:
                    login_state["status"] = "failed"
                    login_state["error"] = "".join(full_output[-5:])
                login_state["process"] = None

        except Exception as e:
            with login_lock:
                login_state["status"] = "failed"
                login_state["error"] = str(e)
                login_state["process"] = None

    thread = threading.Thread(target=_login_thread, daemon=True)
    thread.start()
    return {"ok": True, "status": "started"}


def get_login_status():
    """Check the status of an in-progress login."""
    with login_lock:
        return {
            "status": login_state["status"],
            "url": login_state["url"],
            "error": login_state["error"],
        }


def cancel_login():
    """Cancel an in-progress login."""
    global login_state
    with login_lock:
        proc = login_state.get("process")
        if proc and hasattr(proc, "kill"):
            proc.kill()
        login_state = {"process": None, "url": None, "status": "idle", "error": None}
    return {"ok": True}


# ─── Nomad helpers ───────────────────────────────────────────────────────────

def get_nomad_nodes():
    """Get all cluster nodes from Nomad API."""
    try:
        url = f"{NOMAD_ADDR}/v1/nodes"
        req = urllib.request.Request(url)
        resp = urllib.request.urlopen(req, timeout=5)
        nodes = json.loads(resp.read())
        return [
            {
                "id": n.get("ID", "")[:8],
                "name": n.get("Name", ""),
                "address": n.get("Address", ""),
                "status": n.get("Status", ""),
                "eligibility": n.get("SchedulingEligibility", ""),
            }
            for n in nodes
        ]
    except Exception as e:
        return [{"error": str(e)}]


def get_cluster_auth_status():
    """Query all nodes' account-manager instances for auth status."""
    nodes = get_nomad_nodes()
    results = []

    def fetch_node(node):
        if "error" in node:
            return node
        addr = node.get("address", "")
        if not addr:
            return {**node, "auth": {"error": "no address"}}
        try:
            # Use localhost for this node to avoid firewall issues
            query_addr = "127.0.0.1" if node.get("name") == NODE_NAME else addr
            url = f"http://{query_addr}:{PORT}/api/status"
            req = urllib.request.Request(url)
            resp = urllib.request.urlopen(req, timeout=5)
            auth = json.loads(resp.read())
            return {**node, "auth": auth}
        except Exception as e:
            return {**node, "auth": {"error": str(e), "node": node["name"], "logged_in": False}}

    threads = []
    results_list = [None] * len(nodes)

    for i, node in enumerate(nodes):
        def worker(idx=i, n=node):
            results_list[idx] = fetch_node(n)
        t = threading.Thread(target=worker)
        t.start()
        threads.append(t)

    for t in threads:
        t.join(timeout=8)

    return [r for r in results_list if r is not None]


# ─── HTTP handler ────────────────────────────────────────────────────────────

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass  # Suppress default logging

    def send_json(self, data, status=200):
        body = json.dumps(data, indent=2).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def send_html(self, content, status=200):
        body = content.encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/":
            self.send_html(render_dashboard())
        elif self.path == "/api/status":
            self.send_json(get_auth_status())
        elif self.path == "/api/cluster":
            self.send_json(get_cluster_auth_status())
        elif self.path == "/api/login-status":
            self.send_json(get_login_status())
        else:
            self.send_error(404)

    def do_POST(self):
        if self.path == "/api/logout":
            self.send_json(do_logout())
        elif self.path == "/api/login":
            self.send_json(start_login())
        elif self.path == "/api/cancel-login":
            self.send_json(cancel_login())
        else:
            self.send_error(404)


# ─── Dashboard HTML ──────────────────────────────────────────────────────────

def render_dashboard():
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Monad — Account Manager</title>
<style>
  :root {{
    --bg: #0d1117; --surface: #161b22; --border: #30363d;
    --text: #e6edf3; --muted: #8b949e; --accent: #58a6ff;
    --green: #3fb950; --red: #f85149; --yellow: #d29922; --purple: #bc8cff;
  }}
  * {{ box-sizing: border-box; margin: 0; padding: 0; }}
  body {{
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif;
    background: var(--bg); color: var(--text); line-height: 1.5;
    padding: 24px; max-width: 1000px; margin: 0 auto;
  }}
  h1 {{ font-size: 1.5rem; font-weight: 600; margin-bottom: 4px; }}
  .subtitle {{ color: var(--muted); font-size: 0.85rem; margin-bottom: 24px; }}
  .node-grid {{ display: grid; gap: 16px; }}
  .node-card {{
    background: var(--surface); border: 1px solid var(--border);
    border-radius: 8px; padding: 20px; position: relative;
  }}
  .node-card.this-node {{ border-color: var(--accent); }}
  .node-header {{ display: flex; justify-content: space-between; align-items: center; margin-bottom: 12px; }}
  .node-name {{ font-size: 1.1rem; font-weight: 600; }}
  .node-ip {{ color: var(--muted); font-size: 0.8rem; font-family: monospace; }}
  .badge {{
    display: inline-block; padding: 2px 10px; border-radius: 12px;
    font-size: 0.75rem; font-weight: 600; text-transform: uppercase;
  }}
  .badge-max {{ background: rgba(188,140,255,0.15); color: var(--purple); }}
  .badge-pro {{ background: rgba(210,153,34,0.15); color: var(--yellow); }}
  .badge-none {{ background: rgba(139,148,158,0.15); color: var(--muted); }}
  .badge-unreachable {{ background: rgba(248,81,73,0.15); color: var(--red); }}
  .auth-info {{ margin: 8px 0; }}
  .auth-email {{ font-family: monospace; color: var(--accent); }}
  .auth-status {{ display: flex; align-items: center; gap: 8px; }}
  .dot {{ width: 8px; height: 8px; border-radius: 50%; display: inline-block; }}
  .dot-green {{ background: var(--green); }}
  .dot-red {{ background: var(--red); }}
  .dot-yellow {{ background: var(--yellow); }}
  .actions {{ display: flex; gap: 8px; margin-top: 12px; flex-wrap: wrap; }}
  button {{
    background: var(--surface); border: 1px solid var(--border); color: var(--text);
    padding: 6px 16px; border-radius: 6px; cursor: pointer; font-size: 0.85rem;
    transition: all 0.15s;
  }}
  button:hover {{ border-color: var(--accent); color: var(--accent); }}
  button.danger:hover {{ border-color: var(--red); color: var(--red); }}
  button.primary {{
    background: var(--accent); border-color: var(--accent); color: #0d1117;
  }}
  button.primary:hover {{ opacity: 0.9; }}
  button:disabled {{ opacity: 0.4; cursor: not-allowed; }}
  .login-flow {{
    margin-top: 12px; padding: 12px; background: var(--bg); border-radius: 6px;
    border: 1px solid var(--border); display: none;
  }}
  .login-flow.active {{ display: block; }}
  .login-url {{
    word-break: break-all; color: var(--accent); text-decoration: underline;
    cursor: pointer; font-family: monospace; font-size: 0.85rem;
  }}
  .spinner {{ display: inline-block; width: 14px; height: 14px; border: 2px solid var(--border);
    border-top-color: var(--accent); border-radius: 50%; animation: spin 0.8s linear infinite; }}
  @keyframes spin {{ to {{ transform: rotate(360deg); }} }}
  .refresh-bar {{ display: flex; justify-content: space-between; align-items: center; margin-bottom: 16px; }}
  .refresh-bar button {{ font-size: 0.8rem; }}
  .last-refresh {{ color: var(--muted); font-size: 0.8rem; }}
  .error-msg {{ color: var(--red); font-size: 0.85rem; margin-top: 4px; }}
  .tag {{ font-size: 0.7rem; color: var(--muted); margin-left: 8px; }}
</style>
</head>
<body>

<h1>Monad Account Manager</h1>
<p class="subtitle">Manage Claude authentication across the cluster &middot; {NODE_NAME}</p>

<div class="refresh-bar">
  <span class="last-refresh" id="last-refresh">Loading...</span>
  <button onclick="refreshCluster()">Refresh</button>
</div>

<div class="node-grid" id="nodes">
  <div class="node-card"><div class="spinner"></div> Loading cluster status...</div>
</div>

<script>
const THIS_NODE = "{NODE_NAME}";
const PORT = {PORT};
let clusterData = [];

async function refreshCluster() {{
  try {{
    const resp = await fetch('/api/cluster');
    clusterData = await resp.json();
    renderNodes(clusterData);
    document.getElementById('last-refresh').textContent = 'Last refresh: ' + new Date().toLocaleTimeString();
  }} catch(e) {{
    document.getElementById('nodes').innerHTML =
      '<div class="node-card"><span class="error-msg">Failed to load cluster status: ' + e.message + '</span></div>';
  }}
}}

function renderNodes(nodes) {{
  const grid = document.getElementById('nodes');
  // Sort: this node first, then by name
  nodes.sort((a,b) => {{
    if (a.name === THIS_NODE) return -1;
    if (b.name === THIS_NODE) return 1;
    return (a.name || '').localeCompare(b.name || '');
  }});

  grid.innerHTML = nodes.map(node => {{
    const auth = node.auth || {{}};
    const isThis = node.name === THIS_NODE;
    const loggedIn = auth.logged_in;
    const unreachable = !!auth.error && !auth.logged_in && auth.error !== 'claude not installed';
    const noClaude = auth.error === 'claude not installed';

    let badge = '';
    if (unreachable) badge = '<span class="badge badge-unreachable">unreachable</span>';
    else if (noClaude) badge = '<span class="badge badge-none">no claude</span>';
    else if (!loggedIn) badge = '<span class="badge badge-none">logged out</span>';
    else if (auth.subscription === 'max') badge = '<span class="badge badge-max">max</span>';
    else if (auth.subscription === 'pro') badge = '<span class="badge badge-pro">pro</span>';
    else badge = '<span class="badge badge-none">' + (auth.subscription || 'unknown') + '</span>';

    let statusDot = unreachable ? 'dot-yellow' : loggedIn ? 'dot-green' : 'dot-red';

    let authInfo = '';
    if (loggedIn) {{
      authInfo = '<div class="auth-info"><span class="auth-email">' + (auth.email || '?') + '</span></div>';
    }} else if (noClaude) {{
      authInfo = '<div class="auth-info" style="color:var(--muted)">Claude Code not installed on this node</div>';
    }} else if (unreachable) {{
      authInfo = '<div class="auth-info" style="color:var(--muted)">Account manager not reachable on port ' + PORT + '</div>';
    }} else {{
      authInfo = '<div class="auth-info" style="color:var(--muted)">Not logged in</div>';
    }}

    let actions = '';
    if (isThis && !unreachable && !noClaude) {{
      if (loggedIn) {{
        actions = `
          <div class="actions">
            <button class="danger" onclick="doLogout()">Log out</button>
          </div>`;
      }} else {{
        actions = `
          <div class="actions">
            <button class="primary" onclick="doLogin()">Log in</button>
          </div>
          <div class="login-flow" id="login-flow"></div>`;
      }}
    }} else if (!isThis && !unreachable && !noClaude) {{
      const manageUrl = 'http://' + node.address + ':' + PORT + '/';
      actions = '<div class="actions"><a href="' + manageUrl + '" target="_blank"><button>Manage</button></a></div>';
    }}

    const thisClass = isThis ? ' this-node' : '';
    const thisTag = isThis ? '<span class="tag">this machine</span>' : '';

    return `
      <div class="node-card${{thisClass}}">
        <div class="node-header">
          <div>
            <span class="node-name">${{node.name || '?'}}${{thisTag}}</span>
            <div class="node-ip">${{node.address || '?'}} &middot; ${{node.status || '?'}} &middot; ${{node.eligibility || '?'}}</div>
          </div>
          <div class="auth-status">
            <span class="dot ${{statusDot}}"></span>
            ${{badge}}
          </div>
        </div>
        ${{authInfo}}
        ${{actions}}
      </div>`;
  }}).join('');
}}

async function doLogout() {{
  if (!confirm('Log out of Claude on ' + THIS_NODE + '?')) return;
  try {{
    await fetch('/api/logout', {{method: 'POST'}});
    setTimeout(refreshCluster, 500);
  }} catch(e) {{
    alert('Logout failed: ' + e.message);
  }}
}}

async function doLogin() {{
  const flow = document.getElementById('login-flow');
  flow.classList.add('active');
  flow.innerHTML = '<div class="spinner"></div> Starting login flow...';

  try {{
    const resp = await fetch('/api/login', {{method: 'POST'}});
    const data = await resp.json();
    if (!data.ok) {{
      flow.innerHTML = '<span class="error-msg">' + (data.error || 'Failed to start login') + '</span>';
      return;
    }}
    pollLoginStatus(flow);
  }} catch(e) {{
    flow.innerHTML = '<span class="error-msg">Error: ' + e.message + '</span>';
  }}
}}

async function pollLoginStatus(flow) {{
  const poll = async () => {{
    try {{
      const resp = await fetch('/api/login-status');
      const data = await resp.json();

      if (data.status === 'complete') {{
        flow.innerHTML = '<span style="color:var(--green)">&#10003; Logged in successfully!</span>';
        setTimeout(refreshCluster, 1000);
        return;
      }}
      if (data.status === 'failed') {{
        flow.innerHTML = '<span class="error-msg">Login failed: ' + (data.error || 'unknown error') + '</span>' +
          '<div class="actions" style="margin-top:8px"><button onclick="cancelLogin()">Dismiss</button></div>';
        return;
      }}
      if (data.url) {{
        flow.innerHTML =
          '<p style="margin-bottom:8px">Click to authenticate:</p>' +
          '<a class="login-url" href="' + data.url + '" target="_blank">' + data.url + '</a>' +
          '<p style="margin-top:8px;color:var(--muted);font-size:0.8rem">' +
          '<span class="spinner"></span> Waiting for browser authentication...</p>' +
          '<div class="actions" style="margin-top:8px"><button class="danger" onclick="cancelLogin()">Cancel</button></div>';
      }} else {{
        flow.innerHTML = '<div class="spinner"></div> Waiting for login URL...';
      }}

      setTimeout(poll, 1500);
    }} catch(e) {{
      flow.innerHTML = '<span class="error-msg">Poll error: ' + e.message + '</span>';
    }}
  }};
  poll();
}}

async function cancelLogin() {{
  await fetch('/api/cancel-login', {{method: 'POST'}});
  document.getElementById('login-flow').classList.remove('active');
  refreshCluster();
}}

// Initial load + auto-refresh every 30s
refreshCluster();
setInterval(refreshCluster, 30000);
</script>
</body>
</html>"""


# ─── Main ────────────────────────────────────────────────────────────────────

def main():
    port = PORT
    for arg in sys.argv[1:]:
        if arg == "--port" or arg == "-p":
            continue
        try:
            port = int(arg)
        except ValueError:
            pass

    server = http.server.HTTPServer(("0.0.0.0", port), Handler)
    print(f"[account-manager] {NODE_NAME} listening on http://0.0.0.0:{port}")
    print(f"[account-manager] Dashboard: http://{NODE_NAME}:{port}/")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[account-manager] Shutting down")
        server.shutdown()


if __name__ == "__main__":
    main()
