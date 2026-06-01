# Coordination Protocol — mutually directed investigation

The research agents must not work in isolation on a fixed timetable. This protocol defines
how the cluster behaves as **one investigating organism**: agents surface work, claim it,
hand off to each other, and ask for help — so the output of one agent becomes the directed
input of another.

It composes with mechanisms that already exist (rather than replacing them):
- the math repo's `agents/processor.py` messaging (session letters between agents),
- its `02-court/` dispute system,
- `00-navigation/` (OPEN-QUESTIONS, SESSION-LOG, TANGENTS, hypotheses),
- the cluster-memory key-value store (`scripts/cluster-memory.sh`),
- `claude-monad/math-lean`'s `candidates/` formalization queue.

## The work item

Everything the cluster could do is a **work item**. `frontier.py` produces them; `dispatcher.py`
assigns them. Shape:

```json
{
  "id": "oq-0421",
  "type": "open-question | hypothesis | formalize | court | compute | writeup",
  "source": "math:00-navigation/OPEN-QUESTIONS.md#L42 | math-lean:candidates/redei.md",
  "priority": 0.0-1.0,
  "best_role": "researcher | compute | reviewer | formalizer",
  "status": "open | claimed | active | done | blocked",
  "owner": null
}
```

## The five verbs

1. **surface** — any agent that discovers a new question/result/discrepancy writes it to the
   appropriate canonical location (OPEN-QUESTIONS, a candidate file, a court case). It thereby
   enters the frontier automatically; no separate registration.
2. **claim** — before working, an agent claims the item in cluster-memory
   (`work:<id>=<machine-id>`) so two agents don't duplicate. Claims expire (TTL) so a dead
   agent's item returns to the frontier.
3. **hand off** — when an agent's output *is the input* to another role, it surfaces the
   next item explicitly and addresses a session letter to that role. The canonical chains:
   - researcher proves a theorem → **surfaces a `formalize` candidate** in math-lean → formalizer.
   - formalizer fails to formalize / finds a counterexample → **opens a court case** → reviewer.
   - reviewer resolves a court case → **surfaces an `open-question` or `writeup`** → researcher.
   - compute extends a sequence that breaks a conjecture → **opens a court case** → reviewer.
4. **request help** — an agent stuck on an item posts a help request (session letter, subject
   `HELP <id>`) instead of silently failing. The dispatcher raises that item's priority so
   another agent/account picks it up next cycle.
5. **report** — on finishing, the agent marks the item done (cluster-memory), logs to
   SESSION-LOG, and releases its claim.

## The loop (what the dispatcher runs)

```
every cycle:
  items   = frontier()                      # union of all open work across repos
  free    = idle agents/accounts (max-1/2/3/pro), rate-limit aware
  for each free agent, highest-priority item whose best_role fits:
      claim, dispatch the matching job, record assignment
```

Priority blends: explicit human priority (red questions), staleness (untouched longest),
chain pressure (a formalize item waiting on a fresh proof outranks an old open question), and
help-requests (boosted). The point: the cluster always pulls on whichever thread most needs a
mind, and routes it to the right kind of mind on an account that has quota.

## Account / rate-limit discipline

Each Max account has independent limits (root CLAUDE.md → Rate Limit Isolation). The
dispatcher never puts two heavy items on the same account in one cycle; `pro` is reserved for
short maintenance. This is why assignment is *dynamic per cycle* rather than a static cron —
quota is a live constraint.

## Staged rollout

The dispatcher runs in `--dry-run` first (prints the frontier + proposed assignments, dispatches
nothing). The existing day-of-week cron rotation keeps running until a few dry-run cycles look
right; then `math-dispatcher.hcl` is deployed and the per-role periodic jobs are switched to
parameterized (dispatch-only) jobs. No flag day.
