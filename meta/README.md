# meta/ — the platform & execution layer

`monad/` (the rest of this repo) is the **live cluster**: GitOps job specs, node configs,
self-healing. `meta/` is the **platform underneath the agents** — how a new computer becomes
a participating node, how toolchains are made reproducible, and how agents coordinate to
direct each other's investigation.

It exists because the cluster is growing from a hand-tuned set of nodes into a fleet of
"give Claude to a few computers and let them explore together" machines. That needs three
things this directory provides:

```
meta/
├── images/          Containerized toolchains (hybrid execution model)
│   ├── lean-toolchain/   elan + Lean + warm Mathlib cache  → ghcr.io/claude-monad/lean-toolchain
│   └── compute/          python scientific stack           → ghcr.io/claude-monad/compute
├── bootstrap/       Turn a fresh computer into a cluster node in one command
│   ├── join.sh
│   └── install-toolchains.sh
├── coordination/    Dynamic, integrative cross-agent processes
│   ├── PROTOCOL.md       the contract agents follow to direct each other
│   ├── frontier.py       aggregate the live research frontier into work items
│   └── dispatcher.py     assign the next item to the best idle agent/node
└── execution/       Reproducible builds
    └── run-in-toolchain.sh   run a build inside the toolchain image
```

## The execution model: hybrid

**Claude itself stays native** (`raw_exec`). Each node is logged into one Anthropic account
and jobs are pinned to it via `meta.claude_account` (see the root CLAUDE.md → Account
Architecture). Containerizing Claude would break that account pinning, so we don't.

**Toolchains are containerized.** Lean builds and heavy Python run inside published images
via `execution/run-in-toolchain.sh`, so every node produces identical results regardless of
host drift. Agents are native; their *builds* are reproducible.

```
host (native claude, account-pinned)
   └── agent session
         └── run-in-toolchain.sh lean-toolchain  →  docker run … lake build
```

## How a new computer joins

```bash
curl -sL https://raw.githubusercontent.com/claude-monad/monad/main/meta/bootstrap/join.sh \
  | bash -s -- <server-tailscale-ip> <claude-account>
```

This installs Tailscale, joins the tailnet, installs the Nomad client (via the existing
`scripts/setup-node.sh`), installs toolchains, prompts for `claude` login, tags the node's
`claude_account`, and registers the node-doctor cron. Result: a fresh machine is a full
member of the cluster.

## Coordination: from fixed rotation to mutual direction

Today the research agents run on a fixed day-of-week cron rotation. `coordination/` replaces
that with a **frontier-aware loop**: `frontier.py` reads the live state of the whole system
(open questions, court cases, unformalized Lean candidates, pending hypotheses) and
`dispatcher.py` assigns the next most valuable item to whichever agent/account is best suited
and available. Crucially, agents **spawn work for each other** — a researcher's new theorem
becomes a formalization candidate, the formalizer's failure becomes a court case — so the
cluster pursues *mutually directed* investigation rather than each agent working in
isolation. See [coordination/PROTOCOL.md](./coordination/PROTOCOL.md).

> Cutover from the cron rotation to the dispatcher is a **staged, opt-in** step — the
> existing rotation keeps running until the dispatcher is validated with `--dry-run`.
