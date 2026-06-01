#!/usr/bin/env python3
"""
dashboard.py — Livestream control dashboard.

Web UI + REST API for controlling the restream engine.
Exposed on the Tailnet at http://<node-ip>:8080
"""

from flask import Flask, render_template_string, request, jsonify, Response
import json
import os
import time
import threading
import requests
from xml.etree import ElementTree

# Import restream engine
from restream import engine

app = Flask(__name__)

NGINX_STAT_URL = os.environ.get("NGINX_STAT_URL", "http://127.0.0.1:8088/stat")
ACTIVE_STREAMS = {}  # stream_key -> {started_at, client_ip}

# ─── Dashboard HTML ──────────────────────────────────────────────────────────

DASHBOARD_HTML = """
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <title>Monad Livestream</title>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
        :root {
            --bg: #0a0a0f;
            --card: #12121a;
            --border: #1e1e2e;
            --text: #e0e0e8;
            --muted: #888;
            --accent: #7c5cfc;
            --green: #22c55e;
            --red: #ef4444;
            --yellow: #eab308;
            --blue: #3b82f6;
        }
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
            font-family: 'SF Mono', 'Fira Code', monospace;
            background: var(--bg);
            color: var(--text);
            padding: 20px;
            max-width: 1400px;
            margin: 0 auto;
        }
        h1 { font-size: 1.4em; margin-bottom: 20px; color: var(--accent); }
        h2 { font-size: 1em; margin-bottom: 12px; text-transform: uppercase; letter-spacing: 2px; color: var(--muted); }
        .grid { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; margin-bottom: 20px; }
        .card {
            background: var(--card);
            border: 1px solid var(--border);
            border-radius: 8px;
            padding: 16px;
        }
        .card.full { grid-column: 1 / -1; }
        .status-dot {
            display: inline-block;
            width: 8px; height: 8px;
            border-radius: 50%;
            margin-right: 6px;
        }
        .status-dot.live { background: var(--green); box-shadow: 0 0 8px var(--green); }
        .status-dot.off { background: var(--red); }
        .status-dot.pending { background: var(--yellow); }
        .stream-list { list-style: none; }
        .stream-list li {
            padding: 8px 0;
            border-bottom: 1px solid var(--border);
            display: flex;
            justify-content: space-between;
            align-items: center;
        }
        .stream-list li:last-child { border-bottom: none; }
        button {
            background: var(--accent);
            color: white;
            border: none;
            padding: 6px 14px;
            border-radius: 4px;
            cursor: pointer;
            font-family: inherit;
            font-size: 0.85em;
        }
        button:hover { opacity: 0.85; }
        button.danger { background: var(--red); }
        button.success { background: var(--green); }
        button.small { padding: 4px 8px; font-size: 0.8em; }
        input, select {
            background: var(--bg);
            color: var(--text);
            border: 1px solid var(--border);
            padding: 6px 10px;
            border-radius: 4px;
            font-family: inherit;
            width: 100%;
            margin-bottom: 8px;
        }
        .row { display: flex; gap: 8px; align-items: center; }
        .row input { flex: 1; }
        .preview {
            background: #000;
            border-radius: 4px;
            aspect-ratio: 16/9;
            display: flex;
            align-items: center;
            justify-content: center;
            color: var(--muted);
            margin-bottom: 12px;
            overflow: hidden;
        }
        .preview video { width: 100%; height: 100%; }
        .tag {
            display: inline-block;
            padding: 2px 8px;
            border-radius: 3px;
            font-size: 0.75em;
            font-weight: bold;
        }
        .tag.live { background: var(--green); color: #000; }
        .tag.off { background: var(--border); color: var(--muted); }
        .layout-btn {
            padding: 8px 16px;
            border: 1px solid var(--border);
            background: var(--card);
            color: var(--text);
            cursor: pointer;
            border-radius: 4px;
        }
        .layout-btn.active { border-color: var(--accent); background: var(--accent); color: #fff; }
        #toast {
            position: fixed; bottom: 20px; right: 20px;
            background: var(--card); border: 1px solid var(--border);
            padding: 12px 20px; border-radius: 6px;
            display: none; z-index: 100;
        }
        .meta { color: var(--muted); font-size: 0.8em; }
    </style>
</head>
<body>
    <h1>MONAD LIVESTREAM</h1>

    <div class="grid">
        <!-- Compositor Preview -->
        <div class="card">
            <h2>Composite Output</h2>
            <div class="preview" id="preview">
                <video id="compositePlayer" muted autoplay></video>
            </div>
            <div class="row" style="margin-bottom: 8px;">
                <span class="status-dot" id="compositorDot"></span>
                <span id="compositorStatus">checking...</span>
            </div>
            <div class="row">
                <button class="success" onclick="api('/api/start-all', 'POST')">Go Live</button>
                <button class="danger" onclick="api('/api/stop-all', 'POST')">Stop All</button>
                <button onclick="api('/api/compositor/restart', 'POST')">Restart Compositor</button>
            </div>
        </div>

        <!-- Active Sources -->
        <div class="card">
            <h2>Ingest Sources</h2>
            <ul class="stream-list" id="sourcesList">
                <li class="meta">waiting for streams...</li>
            </ul>
            <h2 style="margin-top: 16px;">Layout</h2>
            <div class="row" id="layoutBtns">
                <button class="layout-btn" data-layout="single" onclick="setLayout('single')">Single</button>
                <button class="layout-btn" data-layout="side-by-side" onclick="setLayout('side-by-side')">Side by Side</button>
                <button class="layout-btn" data-layout="pip" onclick="setLayout('pip')">PiP</button>
            </div>
            <h2 style="margin-top: 16px;">Active in Composite</h2>
            <div id="activeSourcesControl"></div>
        </div>

        <!-- YouTube Output -->
        <div class="card">
            <h2>YouTube</h2>
            <div class="row" style="margin-bottom: 8px;">
                <span class="status-dot" id="youtubeDot"></span>
                <span id="youtubeStatus">not configured</span>
            </div>
            <input id="youtubeUrl" placeholder="RTMP URL (rtmp://a.rtmp.youtube.com/live2)" value="rtmp://a.rtmp.youtube.com/live2">
            <input id="youtubeKey" type="password" placeholder="Stream key">
            <div class="row">
                <button onclick="saveOutput('youtube')">Save</button>
                <button class="success small" onclick="api('/api/output/youtube/start', 'POST')">Start</button>
                <button class="danger small" onclick="api('/api/output/youtube/stop', 'POST')">Stop</button>
            </div>
        </div>

        <!-- Twitch Output -->
        <div class="card">
            <h2>Twitch</h2>
            <div class="row" style="margin-bottom: 8px;">
                <span class="status-dot" id="twitchDot"></span>
                <span id="twitchStatus">not configured</span>
            </div>
            <input id="twitchUrl" placeholder="RTMP URL (rtmp://live.twitch.tv/app)" value="rtmp://live.twitch.tv/app">
            <input id="twitchKey" type="password" placeholder="Stream key">
            <div class="row">
                <button onclick="saveOutput('twitch')">Save</button>
                <button class="success small" onclick="api('/api/output/twitch/start', 'POST')">Start</button>
                <button class="danger small" onclick="api('/api/output/twitch/stop', 'POST')">Stop</button>
            </div>
        </div>

        <!-- OBS Connection Info -->
        <div class="card full">
            <h2>OBS Setup</h2>
            <p>In OBS, set your stream settings to:</p>
            <p style="margin-top: 8px;">
                <strong>Server:</strong> <code>rtmp://{{ tailscale_ip }}:1935/live</code><br>
                <strong>Stream Key:</strong> any name (e.g., <code>cam1</code>, <code>screen</code>, <code>main</code>)
            </p>
            <p class="meta" style="margin-top: 8px;">
                Multiple OBS instances can stream different keys simultaneously. Use the Sources panel above to select which ones go into the composite.
            </p>
        </div>
    </div>

    <div id="toast"></div>

    <script>
    // HLS player for composite preview
    function initPreview() {
        const video = document.getElementById('compositePlayer');
        const src = '/hls-composite/live.m3u8';
        if (video.canPlayType('application/vnd.apple.mpegurl')) {
            video.src = src;
        } else if (typeof Hls !== 'undefined') {
            const hls = new Hls();
            hls.loadSource(src);
            hls.attachMedia(video);
        } else {
            // Fallback: try native
            video.src = src;
        }
    }

    function toast(msg) {
        const t = document.getElementById('toast');
        t.textContent = msg;
        t.style.display = 'block';
        setTimeout(() => t.style.display = 'none', 3000);
    }

    async function api(url, method='GET', body=null) {
        try {
            const opts = { method };
            if (body) { opts.headers = {'Content-Type': 'application/json'}; opts.body = JSON.stringify(body); }
            const res = await fetch(url);
            if (method !== 'GET') {
                const r = await fetch(url, opts);
                const data = await r.json();
                toast(JSON.stringify(data));
                refresh();
                return data;
            }
            return await res.json();
        } catch(e) { toast('Error: ' + e.message); }
    }

    async function saveOutput(platform) {
        const url = document.getElementById(platform + 'Url').value;
        const key = document.getElementById(platform + 'Key').value;
        if (!key) { toast('Stream key required'); return; }
        await fetch('/api/output/' + platform, {
            method: 'POST',
            headers: {'Content-Type': 'application/json'},
            body: JSON.stringify({url, key, enabled: true})
        });
        toast(platform + ' saved');
        refresh();
    }

    async function setLayout(layout) {
        await fetch('/api/layout', {
            method: 'POST',
            headers: {'Content-Type': 'application/json'},
            body: JSON.stringify({layout})
        });
        refresh();
    }

    async function toggleSource(streamKey) {
        const status = await (await fetch('/api/status')).json();
        let sources = status.active_sources || [];
        if (sources.includes(streamKey)) {
            sources = sources.filter(s => s !== streamKey);
        } else {
            sources.push(streamKey);
        }
        await fetch('/api/sources', {
            method: 'POST',
            headers: {'Content-Type': 'application/json'},
            body: JSON.stringify({sources})
        });
        refresh();
    }

    async function refresh() {
        try {
            const status = await (await fetch('/api/status')).json();
            const streams = await (await fetch('/api/streams')).json();

            // Compositor status
            const cDot = document.getElementById('compositorDot');
            const cStatus = document.getElementById('compositorStatus');
            if (status.compositor_running) {
                cDot.className = 'status-dot live';
                cStatus.textContent = 'compositor running';
            } else {
                cDot.className = 'status-dot off';
                cStatus.textContent = 'compositor stopped';
            }

            // Sources list
            const list = document.getElementById('sourcesList');
            if (streams.length > 0) {
                list.innerHTML = streams.map(s => `
                    <li>
                        <span><span class="status-dot live"></span> ${s.key}</span>
                        <span class="meta">${s.client || ''}</span>
                    </li>
                `).join('');
            } else {
                list.innerHTML = '<li class="meta">no active streams</li>';
            }

            // Active sources control
            const ctrl = document.getElementById('activeSourcesControl');
            const allKeys = streams.map(s => s.key);
            const activeSources = status.active_sources || [];
            if (allKeys.length > 0) {
                ctrl.innerHTML = allKeys.map(k => {
                    const active = activeSources.includes(k);
                    return `<button class="${active ? 'success' : ''} small" style="margin: 2px;" onclick="toggleSource('${k}')">${k} ${active ? '✓' : ''}</button>`;
                }).join('');
            } else {
                ctrl.innerHTML = '<span class="meta">no streams to select</span>';
            }

            // Layout buttons
            document.querySelectorAll('.layout-btn').forEach(btn => {
                btn.classList.toggle('active', btn.dataset.layout === status.layout);
            });

            // Output statuses
            for (const platform of ['youtube', 'twitch']) {
                const dot = document.getElementById(platform + 'Dot');
                const stat = document.getElementById(platform + 'Status');
                const config = (status.outputs || {})[platform];
                const isActive = (status.active_processes || []).includes(platform);

                if (isActive) {
                    dot.className = 'status-dot live';
                    stat.textContent = 'streaming';
                } else if (config && config.key) {
                    dot.className = 'status-dot off';
                    stat.textContent = 'configured (stopped)';
                    document.getElementById(platform + 'Url').value = config.url || '';
                } else {
                    dot.className = 'status-dot off';
                    stat.textContent = 'not configured';
                }
            }
        } catch(e) {
            console.error('refresh error:', e);
        }
    }

    // Auto-refresh every 3 seconds
    setInterval(refresh, 3000);
    refresh();
    setTimeout(initPreview, 1000);
    </script>
    <!-- HLS.js for browsers that don't support HLS natively -->
    <script src="https://cdn.jsdelivr.net/npm/hls.js@latest"></script>
</body>
</html>
"""

# ─── API Routes ──────────────────────────────────────────────────────────────

@app.route("/")
def index():
    # Get Tailscale IP for OBS connection info
    import subprocess
    try:
        ts_ip = subprocess.check_output(["tailscale", "ip", "-4"], text=True).strip()
    except Exception:
        ts_ip = "TAILSCALE_IP"
    return render_template_string(DASHBOARD_HTML, tailscale_ip=ts_ip)

@app.route("/api/status")
def api_status():
    return jsonify(engine.get_status())

@app.route("/api/streams")
def api_streams():
    """Get active ingest streams from nginx-rtmp stats."""
    streams = []
    try:
        resp = requests.get(NGINX_STAT_URL, timeout=2)
        root = ElementTree.fromstring(resp.content)
        for app in root.iter("application"):
            app_name = app.find("name")
            if app_name is not None and app_name.text == "live":
                for stream in app.iter("stream"):
                    name = stream.find("name")
                    if name is not None:
                        client = ""
                        cl = stream.find("client")
                        if cl is not None:
                            addr = cl.find("address")
                            client = addr.text if addr is not None else ""
                        bw = stream.find("bw_video")
                        streams.append({
                            "key": name.text,
                            "client": client,
                            "bw_video": int(bw.text) if bw is not None else 0
                        })
    except Exception:
        pass
    return jsonify(streams)

@app.route("/api/output/<platform>", methods=["POST"])
def api_set_output(platform):
    data = request.json or {}
    url = data.get("url", "")
    key = data.get("key", "")
    enabled = data.get("enabled", True)
    engine.set_output(platform, url, key, enabled)
    return jsonify({"ok": True})

@app.route("/api/output/<platform>/start", methods=["POST"])
def api_start_output(platform):
    return jsonify(engine.start_output(platform))

@app.route("/api/output/<platform>/stop", methods=["POST"])
def api_stop_output(platform):
    return jsonify(engine.stop_output(platform))

@app.route("/api/layout", methods=["POST"])
def api_set_layout():
    data = request.json or {}
    engine.set_layout(data.get("layout", "single"))
    return jsonify({"ok": True})

@app.route("/api/sources", methods=["POST"])
def api_set_sources():
    data = request.json or {}
    engine.set_sources(data.get("sources", []))
    return jsonify({"ok": True})

@app.route("/api/compositor/start", methods=["POST"])
def api_start_compositor():
    return jsonify(engine.start_compositor())

@app.route("/api/compositor/stop", methods=["POST"])
def api_stop_compositor():
    return jsonify(engine.stop_compositor())

@app.route("/api/compositor/restart", methods=["POST"])
def api_restart_compositor():
    return jsonify(engine.restart_compositor())

@app.route("/api/start-all", methods=["POST"])
def api_start_all():
    return jsonify(engine.start_all())

@app.route("/api/stop-all", methods=["POST"])
def api_stop_all():
    return jsonify(engine.stop_all())

# ─── nginx-rtmp hooks ────────────────────────────────────────────────────────

@app.route("/api/hooks/on_publish")
def hook_on_publish():
    """Called by nginx-rtmp when a new stream starts."""
    name = request.args.get("name", "")
    addr = request.args.get("addr", "")
    ACTIVE_STREAMS[name] = {"started_at": time.time(), "client_ip": addr}
    # Auto-add to active sources if none configured
    status = engine.get_status()
    if not status["active_sources"]:
        engine.set_sources([name])
    return "", 200

@app.route("/api/hooks/on_publish_done")
def hook_on_publish_done():
    """Called by nginx-rtmp when a stream stops."""
    name = request.args.get("name", "")
    ACTIVE_STREAMS.pop(name, None)
    # Remove from active sources
    status = engine.get_status()
    if name in status["active_sources"]:
        sources = [s for s in status["active_sources"] if s != name]
        engine.set_sources(sources)
    return "", 200

# ─── HLS proxy (serve nginx-rtmp HLS through dashboard port) ────────────────

@app.route("/hls-composite/<path:filename>")
def hls_proxy(filename):
    """Proxy HLS segments from nginx-rtmp HTTP server."""
    try:
        resp = requests.get(f"http://127.0.0.1:8088/hls-composite/{filename}", timeout=2)
        content_type = "application/vnd.apple.mpegurl" if filename.endswith(".m3u8") else "video/mp2t"
        return Response(resp.content, content_type=content_type)
    except Exception:
        return "", 404

# ─── Main ────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    import atexit
    atexit.register(engine.cleanup)

    port = int(os.environ.get("DASHBOARD_PORT", 8080))
    print(f"[livestream] Dashboard starting on port {port}")
    app.run(host="0.0.0.0", port=port, debug=False)
