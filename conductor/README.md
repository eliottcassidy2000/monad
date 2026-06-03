# The Cluster Conductor

A **single, always-on Claude instance** that runs the cluster on the owner's behalf.
The owner no longer queries Claude directly on individual machines — everything flows
through the conductor. It lives in a container on **oraclebox1** (where the account
credentials are), with host networking so it sees the tailnet directly.

## Two front doors, one brain

### 1. Tailscale text gateway  (query the cluster as text)
```
curl -s -X POST http://100.125.210.126:8200/ask -d 'how is the cluster doing?'
curl -s http://100.125.210.126:8200/health        # status + uptime snapshot
```
- `POST /ask` body: raw text or JSON `{"text": "..."}` → the conductor's text reply.
- Every `/ask` continues the **same** conversation (session-pinned). Send `/reset` to
  start a fresh thread.
- Tailnet-only (binds the node's Tailscale IP, never `0.0.0.0`). Optional bearer token
  via `CONDUCTOR_TOKEN`.

### 2. Remote-control session  (guide it from the Claude app)
On launch the conductor starts `claude --remote-control cluster-conductor`, which
registers with the account and is reachable from the Claude app (desktop **and phone**)
at `claude.ai/code`. Open the app, pick the `cluster-conductor` session, and drive it.

## What it can do
It has, on this node: `nomad` (cluster ops), `tailscale` (mesh/ping), the `monad` CLI,
the GitOps repo (it can commit/push), and the containerized dispatch (`meta/dispatch/`).
Its standing context is `conductor/CONDUCTOR.md` (its role, the connectivity mission,
the 3-master convergence task).

## How it stays up
**Nomad-managed** (the cluster idiom). The image lives on GHCR
(`ghcr.io/eliott-monad/monad-conductor:latest`) and `jobs/cluster-conductor.hcl` runs it
as a `service` job pinned to oraclebox1, with the GHCR pull token + GitOps push token
templated from the Nomad variable `nomad/jobs/cluster-conductor` (auto-readable by the
task's workload identity — no committed credentials). Nomad restarts it on failure.
```
# rebuild + push the image after changing conductor code, then redeploy:
conductor/push-image.sh                 # build + push to GHCR, store pull token
nomad job run jobs/cluster-conductor.hcl
```
A standalone fallback (`conductor/redeploy.sh`) runs it as a plain
`docker --restart unless-stopped` container if Nomad is unavailable.

## One account — the important caveat
The whole cluster shares **one** Claude account. The conductor is meant to be its
**primary** consumer. Running other heavy Claude sessions on the same account at the
same time (the autonomous math fleet, or a human session) **contends on the shared
credential** and can make conductor calls slow or stall. Operate the conductor as the
single live consumer, or stagger the autonomous jobs. The robust long-term fix (a warm
`claude --print --input-format stream-json` backend shared by both doors, so there is
exactly one warm process) is the documented next step — a good cluster task.

## Files
- `gateway.py` — the Tailscale text HTTP service (session-pinned, serialized).
- `start-conductor.sh` — launcher: git auth, RC-session watchdog, then the gateway.
- `CONDUCTOR.md` — the conductor's standing system prompt / role.
- `Dockerfile` — the lean `monad-conductor` image (claude + tmux + python; host tools mounted).
- `redeploy.sh` — build the image + (re)launch the container with the right mounts.
- `../jobs/cluster-conductor.hcl` — Nomad service form (pending a registry image).
