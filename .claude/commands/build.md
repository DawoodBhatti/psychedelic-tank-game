---
description: Run the Doer/Reviewer loop on a task until the Reviewer approves or the budget runs out.
argument-hint: <what to build>
---

Drive the Doer/Reviewer loop to completion on this task:

**$ARGUMENTS**

You are the **orchestrator**. You do not write game code yourself and you do not run the
tests yourself — the agents do. Your job is to run the cycle, carry feedback between them,
count the budget, and know when to stop.

## Before the first spawn

**Grep for the noun the task names, and check it resolves to one thing.** "Increase the
firefly's thrust" named `firefly/firefly.gd`, which holds no thrust at all — it sat on the
parent as `FORWARD_THRUST` *and* `REVERSE_THRUST`, three defensible readings, each a one-line
edit, **each passing all six tests.** Nothing downstream catches the wrong pick: the sequence
checks that the code does what the *Doer* meant, never that the Doer meant what the *user* did.

If it resolves to more than one candidate, ask before spawning. One grep and one question,
against a wasted Doer turn and a full Reviewer sweep.

**Then check that file is not already modified** — `git status --short <path>`. **Run the
command** — the session-start `gitStatus` block has been seen naming a file that did not exist
yet, and stopping on that is a false stop.

Modified → **capture the baseline off the dirty tree first**, in one batched launch, before
anything else. That is free, it is the one chance, and it is right whatever the user then
decides. The "before" is in the WORKING TREE, not at HEAD.

Then stop and ask. The risk is **not** an unobtainable before — it is that `git checkout` can
no longer separate this task's damage from the uncommitted work already there. That argues for
committing, and only for committing. **Do not offer `stash`**: where HEAD is a different world
from the tree, stashing replaces the baseline with one describing something the task is not
about, and the run is then tuned against it. That has been within one command of happening.

**Where the task rests on a decision a plan marks "locked", check its arithmetic against the
engine constants before writing the brief.** A locked row is an unverified claim wearing a
decision's clothes, and it is copied into briefs verbatim sessions later. One that reached a
brief here required a detail layer under a third of one voxel, and asked for a union that is
`maxf()` in the height domain — both refutable from numbers already on disk, and both would
have passed all six tests. `voxel_size`, `chunk_resolution` and the world footprint are the
usual denominators.

**If the gate is "nothing visibly changes", the before batch is the WHOLE harness surface, not
the part the task appears to be about.** A "before" has one chance — the first edit destroys it
permanently — and you are the party least able to predict what a refactor will touch.
`--harness-eval` repeats, so eight names cost the same boot as three. Enumerate them from
`main.gd`'s header, not from the task.

## The cycle

1. **Spawn `doer`** with the task, plus any Reviewer feedback from a previous round.
   Require it to report: what it changed, the numbers it relied on, and explicitly what it
   did *not* verify.

   Then read what it actually spent: `.claude/scripts/budget.sh`. **Never carry an agent's
   self-reported launch count into the next brief** — CLAUDE.md § Budgets says why not.

2. **Spawn `reviewer`** with the original task, the Doer's stated plan and its report.
   The Reviewer needs the intent, not just the diff — it is judging whether the change does
   what was asked, not only whether it runs.

   Name the one or two claims that actually matter (a collision layer, the value the change
   turns on) and let `reviewer.md` govern the rest. Do NOT ask it to re-measure everything —
   that costs one engine boot per question and finds nothing a spot-check would miss.

3. **Read the verdict.**
   - **Approve** → go to Finishing.
   - **Send back** → continue the SAME doer via SendMessage rather than spawning a fresh one.
     It keeps its context, and `doer.md` tells it to address the specific feedback rather
     than restart. A cold agent re-derives everything and often rewrites work that was fine.

     **An agent killed mid-run — usage limit, API error, stall watchdog — is resumed the same
     way, never respawned cold.** Recover what it already bought from **disk**:
     `git status --short` and the files it left, whose headers carry their own design
     contract. Then restate the brief *and what it already measured*, or it re-buys launches
     already paid for. Its `.output` transcript (100k+ tokens — `offset` near the end, `limit`
     3–4) answers only what it *concluded* and never wrote down: open it when the artifacts do
     not, not by default.
   - Then loop to step 2.

## Budget

`CLAUDE.md § Budgets` carries both counters and their rules. Yours on top of that: **report
both counts in your summary**, and treat a hook denial as the wall — stop immediately and
report status rather than continuing or raising the ceiling.

## Stop early and hand back to the user when

- **The render check FAILS.** A visual change on its own is not a stopping condition — the
  Reviewer answers "does it render" mechanically and that has a right answer. Send a failed
  render check back to the Doer like any other failure. Only surface it to the user if it
  cannot be fixed. Taste is reviewed afterwards from the screenshots, not mid-loop.
- **The Reviewer sends the same feedback twice running.** That is a loop that is not
  converging; another round will not fix it.
- **The task turns out to need a decision rather than an implementation** — an ambiguity in
  what was asked, or a trade-off with no obviously right answer. Ask, do not guess.

## Learnings

**The Reviewer cannot write.** It ends its report with any entry the review surfaced, in
inbox format, and **you file that verbatim** — it is not yours to re-judge. You then file
what **you** noticed that was never a
Reviewer finding — the seam between commands, the adjacent risk spotted while reading around
the change, the assumption the task turned out to rest on. That category is real and the loop
has no other home for it: the highest-value fold of the run that created this mechanism was a
repository risk nobody's report had listed.

Write to `.claude/learnings/` per `.claude/learnings/README.md`, and do it before the summary
while it is still cheap to recall. **Do not apply it** — folding happens in `/consolidate`, in
a fresh session, with the user there.

Zero entries is the ordinary outcome. Do not manufacture one to have something to report.

## Finishing

Report to the user:
- What was built, in a sentence or two.
- The Reviewer's final measured numbers (fps, load time, resources, any values verified).
- Budget used, quoting `.claude/scripts/budget.sh` rather than a tally.
- What the run cost. Run `python .claude/scripts/usage_report.py` and report three numbers:
  total effective tokens, the context size now, and the cost of one more turn. If the context
  is past 300k, say plainly that the next task should start in a fresh session.
- Anything left unverified, especially anything visual awaiting their eye.
- **Whether the tree is left dirty, and which files.** The next session cannot tell
  uncommitted work from work in progress.
- Anything you stopped short of, and why.
- **How many entries are sitting in `.claude/learnings/`**, including any this run added. That
  count is the only signal the user gets that a `/consolidate` session is worth spending.

Do not commit or push. That stays the user's call.
