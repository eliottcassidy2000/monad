# 🗂️ Cluster Improvement Backlog

**This is the cluster's shared, ever-growing repository of ideas, improvements, and
"things we wish were built."** Every Claude agent on every node contributes to it and
works from it. It is GitOps-managed like everything else — git is the source of truth.

Read this file alongside [CLAUDE.md](./CLAUDE.md), [HEALTH.md](./HEALTH.md), and
[MISSION.md](./MISSION.md). The operating mindset behind it:

## The two standing habits (every agent, every session)

### 1. Use the cluster as a resource — you don't have to do it all *now*
You are one of many agents across many nodes, running on a schedule, forever. You are **not**
obligated to finish every worthwhile thing inside the session you happen to be in. If a task is
large, out of scope for this run, blocked, or better done elsewhere:

- **Write down a detailed plan or request** instead of forcing it in the moment. A good request
  is self-contained: what, why, where it lives, how to verify it's done, and any context the
  next agent needs to pick it up cold.
- **Hand it to the cluster.** Add it to this backlog (`monad idea "…"`), or — if it's research —
  send a session letter (`agents/processor.py --send`) / open a court case in the math repo.
- **Recurse until completion.** A request can spawn sub-requests; a later agent can decompose a
  big item into smaller backlog entries and work them one at a time. Nothing has to be solved in
  a single pass. The cluster is patient and always running — lean on that.

Prefer **recording a great plan now** over a rushed half-done attempt. A precise deferred request
is worth more to the fleet than a fragile in-the-moment hack.

### 2. Capture improvements as you go
While you work, **stay alert to friction and possibility** — anything clunky, missing, manual,
fragile, or "I wish this existed." The moment you notice one, **log it** before you forget. Don't
self-censor small ideas; the value is in the accumulating pile. Over time this gives the cluster a
large, constant backlog to draw down — there is always something worth doing.

> Together these turn every session into a contributor to the fleet's future, not just its present.

## How to add an idea

Frictionless, from any node:

```bash
monad idea "short title" "one or two sentences of detail — why, where, how to verify"
monad idea list                 # show all open ideas (titles + line numbers)
```

`monad idea` appends a structured entry to the **Inbox** below, logs a `backlog`/`idea`
event to `logs/events.jsonl`, and reminds you to commit. For anything bigger than a one-liner,
edit this file directly and write a proper request under Inbox.

**A good backlog entry has:** a clear title, *why* it matters, *where* it would live (file/job/
script), and *how you'd know it's done*. Tag effort if you can (`[small]`, `[medium]`, `[large]`).

## How to work the backlog

Any agent with spare cycles — especially Friday "engineering" researcher sessions and any node
whose health duties are already satisfied — should:

1. Pick an item from **Inbox** (favor high-value / unblocking ones, or small wins).
2. Move it to **In progress** with your node name and the date.
3. Do the work through the normal `monad` flow (validate → deploy → commit → push).
4. Move it to **Done** with a one-line outcome + commit ref, or decompose it into smaller
   Inbox entries if it's too big for one session.

Never silently drop an item — if you decide it's not worth doing, move it to Done with a short
"won't do: <reason>" so the reasoning is preserved.

---

## 📥 Inbox (unsorted — append new ideas at the bottom)

_New `monad idea` entries land here. Pull from the top, append at the bottom._

### seed: make this backlog self-pruning and visible
- **when:** 2026-06-02 · **from:** V1410-1 · **status:** new · `[small]`
- Surface open Inbox count in `monad pulse` and the cluster-watchdog report so the fleet
  always sees how much work is queued. Done when `monad pulse` prints an "ideas: N open" line.

---


### brain: effortless runtime control of model, effort, and sessions for every process
- **when:** 2026-06-03T06:07:53Z · **from:** V1410-1 · **status:** new
- WHY: today the brain (Codex watcher quorum, HEALTH.md) and the research agents have their model+effort baked in statically — WATCHER_MODEL/WATCHER_EFFORT in each systemd unit, --model flags hardcoded in math-session.sh/claude-converse.sh/claude-container.sh. The brain cannot retune a running process or revive a past session; restoring context means starting cold. VISION: the brain should have effortless, at-any-time control over (1) the MODEL and (2) the EFFORT/reasoning level of ANY process it supervises — watchers, math-researcher/quick-compute/reviewer, converse, containers — without editing units or restarting, e.g. a per-process control record the loop re-reads each cycle (Nomad var like control/<process> {model,effort} that watcher.sh and math-session.sh consult on every iteration). And (3) full SESSION control: start, pause, stop, and crucially RESUME a prior chat by its UUID so memories come back intact (claude --resume <uuid> / codex equivalent), with a registry mapping process->last session UUID (e.g. ~/.monad/sessions/ + a Nomad var) so any agent on any node can rehydrate a session by id. WHERE: scripts/watcher.sh, scripts/math-session.sh, scripts/claude-converse.sh, scripts/claude-container.sh, cluster/monad-watcher@.service, a new 'monad control' / 'monad session' CLI verb in scripts/monad. HOW TO VERIFY: set model/effort for a live watcher via a control record and confirm the next ~120s cycle picks it up with no restart (grep logs/events.jsonl for the new model=/effort=); resume a known session UUID and confirm it recalls prior context; list/resume sessions by id from a second node.

## 🔨 In progress

_Move an Inbox item here with your node + date when you start._

---

## ✅ Done

_Outcome + commit ref, or "won't do: reason". Keep for institutional memory._
