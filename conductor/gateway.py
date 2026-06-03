#!/usr/bin/env python3
"""gateway.py — the Cluster Conductor's Tailscale text front door.

An always-on HTTP service, bound to this node's Tailscale IP, that forwards plain
text requests to a single, continuity-preserving headless Claude session (the
"conductor") and returns its text reply. This is how the owner queries/guides the
whole cluster as text, without touching individual machines.

Endpoints
  GET  /            usage
  GET  /health      JSON: uptime, last query time, cluster snapshot
  POST /ask         body = raw text OR {"text": "..."}  ->  {"reply": "..."}
                    (text/plain bodies get a text/plain reply, for curl-friendliness)

Design
  * Continuity: the conductor is ONE evolving Claude conversation. We pin a session
    id and `--resume` it on every request, so the owner can carry a thread.
  * Account-singularity: requests are SERIALIZED behind a lock — at most one Claude
    process at a time (the whole cluster shares one Max account; the conductor is
    its primary consumer).
  * Boundary: bind to the Tailscale IP only (private tailnet), never 0.0.0.0. An
    optional shared token (CONDUCTOR_TOKEN) adds a second check.

Env
  CONDUCTOR_BIND      ip to bind (default: `tailscale ip -4` first address)
  CONDUCTOR_PORT      port (default 8200)
  CONDUCTOR_WORKDIR   cwd for Claude (default: the monad repo root)
  CONDUCTOR_SYSPROMPT path to a system-prompt file (default conductor/CONDUCTOR.md)
  CONDUCTOR_SESSION   session id file (default conductor/.session-id)
  CONDUCTOR_TOKEN     optional shared secret; if set, requests must send
                      `Authorization: Bearer <token>` or `?token=`
  CONDUCTOR_TIMEOUT   per-request Claude wall-clock seconds (default 600)
  NOMAD_ADDR          passed through to Claude for cluster ops
"""
from __future__ import annotations
import json, os, subprocess, sys, threading, time, uuid
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

HERE = os.path.dirname(os.path.abspath(__file__))
MONAD_ROOT = os.path.abspath(os.path.join(HERE, ".."))

WORKDIR   = os.environ.get("CONDUCTOR_WORKDIR", MONAD_ROOT)
SYSPROMPT = os.environ.get("CONDUCTOR_SYSPROMPT", os.path.join(HERE, "CONDUCTOR.md"))
SESS_FILE = os.environ.get("CONDUCTOR_SESSION", os.path.join(HERE, ".session-id"))
TOKEN     = os.environ.get("CONDUCTOR_TOKEN", "")
TIMEOUT   = int(os.environ.get("CONDUCTOR_TIMEOUT", "600"))
PORT      = int(os.environ.get("CONDUCTOR_PORT", "8200"))

_lock = threading.Lock()
_state = {"started": time.time(), "last_query": None, "queries": 0}


def log(*a):
    print("[conductor]", *a, flush=True)


def default_bind() -> str:
    try:
        out = subprocess.run(["tailscale", "ip", "-4"], capture_output=True,
                             text=True, timeout=10).stdout
        for line in out.splitlines():
            if line.strip():
                return line.strip()
    except Exception:
        pass
    return "127.0.0.1"


def session_id() -> str:
    """Stable conductor session id, so every request continues the same thread."""
    try:
        if os.path.isfile(SESS_FILE):
            sid = open(SESS_FILE).read().strip()
            if sid:
                return sid
    except Exception:
        pass
    sid = str(uuid.uuid4())
    try:
        os.makedirs(os.path.dirname(SESS_FILE), exist_ok=True)
        open(SESS_FILE, "w").write(sid)
    except Exception:
        pass
    return sid


def reset_session() -> str:
    try:
        if os.path.isfile(SESS_FILE):
            os.remove(SESS_FILE)
    except Exception:
        pass
    return session_id()


def ask_claude(text: str) -> tuple[str, int]:
    """Run one headless Claude turn in the conductor session. Serialized."""
    sid = session_id()
    sysprompt_args = []
    if os.path.isfile(SYSPROMPT):
        try:
            sysprompt_args = ["--append-system-prompt", open(SYSPROMPT).read()]
        except Exception:
            sysprompt_args = []
    env = dict(os.environ)
    env.setdefault("NOMAD_ADDR", "http://%s:4646" % default_bind())

    def build(resume: bool):
        cmd = ["claude", "--print", "--dangerously-skip-permissions",
               "--permission-mode", "bypassPermissions"]
        cmd += sysprompt_args
        if resume:
            cmd += ["--resume", sid]
        else:
            cmd += ["--session-id", sid]
        cmd += [text]
        return cmd

    with _lock:
        _state["last_query"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        _state["queries"] += 1
        # Try to resume the pinned session; if it doesn't exist yet, start it.
        resume = os.path.isfile(SESS_FILE + ".started")
        try:
            r = subprocess.run(build(resume), cwd=WORKDIR, env=env,
                               capture_output=True, text=True, timeout=TIMEOUT)
            if resume and r.returncode != 0 and "No conversation found" in (r.stdout + r.stderr):
                # session was lost (e.g. fresh container) — start a new one
                sid2 = reset_session()
                r = subprocess.run(build(False), cwd=WORKDIR, env=env,
                                   capture_output=True, text=True, timeout=TIMEOUT)
            open(SESS_FILE + ".started", "w").write("1")
            out = (r.stdout or "").strip()
            if r.returncode != 0:
                err = (r.stderr or "").strip()
                return (out + "\n" + err).strip() or "(claude exited %d, no output)" % r.returncode, r.returncode
            return out, 0
        except subprocess.TimeoutExpired:
            return "(conductor timed out after %ds — the request may be too heavy; try a narrower ask)" % TIMEOUT, 124
        except Exception as e:
            return "(conductor error: %s)" % e, 1


def cluster_snapshot() -> dict:
    snap = {}
    try:
        p = os.path.join(MONAD_ROOT, "logs", "cluster-uptime-summary.json")
        if os.path.isfile(p):
            s = json.load(open(p))
            snap = {
                "avg_connectivity_pct": s.get("avg_connectivity_pct"),
                "avg_cluster_pct": s.get("avg_cluster_pct"),
                "last_updated": s.get("last_updated"),
            }
    except Exception:
        pass
    return snap


USAGE = """Cluster Conductor — text front door (Tailscale)

  POST /ask    body: raw text, or JSON {"text": "..."}    -> the conductor's reply
  GET  /health                                            -> status JSON
  GET  /                                                  -> this help

Example:
  curl -s -X POST http://%s:%d/ask -d 'how is the cluster doing?'

Continuity: every /ask continues the SAME conductor conversation. Send the word
'/reset' as the body to start a fresh thread.
"""


def authorized(handler) -> bool:
    if not TOKEN:
        return True
    auth = handler.headers.get("Authorization", "")
    if auth == "Bearer " + TOKEN:
        return True
    q = parse_qs(urlparse(handler.path).query)
    return q.get("token", [""])[0] == TOKEN


class H(BaseHTTPRequestHandler):
    server_version = "ClusterConductor/1.0"

    def _send(self, code, body, ctype="text/plain"):
        b = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def log_message(self, *a):
        pass  # quiet; we log our own

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/health":
            body = json.dumps({
                "status": "up",
                "uptime_s": int(time.time() - _state["started"]),
                "queries": _state["queries"],
                "last_query": _state["last_query"],
                "workdir": WORKDIR,
                "cluster": cluster_snapshot(),
            }, indent=2)
            return self._send(200, body, "application/json")
        if path == "/":
            return self._send(200, USAGE % (default_bind(), PORT))
        return self._send(404, "not found\n")

    def do_POST(self):
        if urlparse(self.path).path != "/ask":
            return self._send(404, "not found\n")
        if not authorized(self):
            return self._send(401, "unauthorized\n")
        n = int(self.headers.get("Content-Length", "0") or "0")
        raw = self.rfile.read(n).decode("utf-8", "replace") if n else ""
        ctype = self.headers.get("Content-Type", "")
        text = raw
        if "application/json" in ctype:
            try:
                text = json.loads(raw).get("text", "")
            except Exception:
                text = raw
        text = (text or "").strip()
        if not text:
            return self._send(400, "empty request\n")
        if text == "/reset":
            reset_session()
            try:
                os.remove(SESS_FILE + ".started")
            except Exception:
                pass
            return self._send(200, "conductor conversation reset.\n")
        log("ask:", text[:120].replace("\n", " "))
        reply, rc = ask_claude(text)
        log("rc=%d reply_len=%d" % (rc, len(reply)))
        if "application/json" in ctype:
            return self._send(200, json.dumps({"reply": reply, "rc": rc}), "application/json")
        return self._send(200, reply + "\n")


def main():
    bind = os.environ.get("CONDUCTOR_BIND", default_bind())
    httpd = ThreadingHTTPServer((bind, PORT), H)
    log("conductor gateway on http://%s:%d  (workdir=%s, session-pinned)" % (bind, PORT, WORKDIR))
    log("auth:", "token required" if TOKEN else "tailnet-only (no token)")
    httpd.serve_forever()


if __name__ == "__main__":
    main()
