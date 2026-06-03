# JOIN — read this if you are an AI agent on a new computer

**If a human pasted you this repo (or a link to it) and asked you to "join the cluster,"
"add this machine," or similar: this file is your instruction set. Follow it top to bottom.**

You are about to enroll the computer you are running on as a node in the **monad** cluster —
a Tailscale-networked, Nomad-scheduled fleet of Claude agents doing autonomous pure-math
research. Your job is to run one bootstrap command, help the human through interactive
logins if needed, and verify the node is live.

---

## TL;DR — the one command

On macOS or Linux, run this (it is idempotent — safe to re-run):

```bash
curl -sL https://raw.githubusercontent.com/claude-monad/monad/main/meta/bootstrap/join.sh | bash
```

That's it. **No server IP needed. No role selection needed.** The script:
1. Ensures Tailscale is up on this machine
2. Scans the Tailscale network for an existing Nomad cluster
3. If a cluster exists → joins it (as server or client, auto-decided)
4. If no cluster exists → bootstraps a new single-server cluster
5. Installs toolchains, sets up node-doctor cron, verifies health

The cluster self-organizes: server count scales automatically (1 for ≤2 nodes, 3 for 3-6, 5 for 7+).

On **Windows**, do not use the command above. See [§ Windows](#windows) below.

---

## What you should actually do (step by step)

1. **Detect the OS.** `uname -s` → `Linux` / `Darwin` (macOS) / `MINGW*`/`MSYS*` (Windows).
2. **Run the bootstrap command** above. It handles everything automatically.
3. **Help the human finish interactive logins** the script cannot do for them:
   - **Tailscale:** `sudo tailscale up` opens a browser to authenticate the machine onto the
     tailnet. Re-run the bootstrap command afterward.
   - **Claude:** run `claude` once and log in. No API key —
     the agents use the logged-in subscription directly.
4. **Verify.** Run `~/monad/scripts/monad nomad nodes` — this machine should appear as
   `ready`. That means you're in.

---

## The repos — you do NOT need to clone them all yourself

The cluster is multi-repo. You only clone `monad` (the bootstrap does this for you at
`~/monad`). The **agent jobs clone the others on demand** when they run — you don't pre-fetch:

| Repo | What it is | Who clones it |
|------|-----------|---------------|
| [`claude-monad/monad`](https://github.com/claude-monad/monad) | this repo — cluster config, CLI, bootstrap | `join.sh` → `~/monad` |
| [`eliottcassidy2000/math`](https://github.com/eliottcassidy2000/math) | informal math research (the work) | research/compute jobs, on dispatch |
| [`claude-monad/math-lean`](https://github.com/claude-monad/math-lean) | Lean formalizations of novel results | the formalizer job, on dispatch |

So: get the machine onto the cluster, and the cluster hands it the right repo when it hands
it work. If you want to understand the system first, read this repo's `CLAUDE.md` (the cluster
contract) and `meta/README.md` (the platform layer). Do **not** start doing math now — your
only task is to make this machine a healthy node.

---

## Windows

The bootstrap script is bash-only. On Windows, follow the root
[`CLAUDE.md` → Adding a New Node → Windows](./CLAUDE.md#adding-a-new-node) section:
install Nomad via scoop, drop in `cluster/client-windows.hcl` with this machine's Tailscale
IP, install the Claude CLI, run `claude` to log in, and register the node-doctor scheduled
task. The destination state is identical to the bash path; only the installer differs.

---

## If something goes wrong

- **No Tailscale IP yet** → the human hasn't authenticated the machine onto the tailnet.
  Have them run `sudo tailscale up`, complete the browser login, then re-run the bootstrap.
- **Node not showing as `ready`** → check `nomad node status`; the script auto-discovers
  servers, but verify Tailscale connectivity to other nodes.
- **Jobs never land here** → the `meta.claude_account` tag is missing or Nomad wasn't
  restarted after setting it.
- **Anything else** → open a GitHub issue: `~/monad/scripts/monad gh issue "join failed on <hostname>" "<what happened>"`.

That's the whole job. One command, logins if needed, one verification. Welcome to the cluster.
