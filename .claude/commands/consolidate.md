---
description: Fold the learnings inbox into the pipeline, preferring enforcement over prose.
argument-hint: (optional) a single learning file to fold
---

Fold `.claude/learnings/` into the pipeline.

**Run this in a fresh session.** Context grows monotonically and is never reclaimed, so this
belongs at the start of a cheap session rather than bolted onto the end of an expensive one.
It is also why it is not part of `/build`: consolidating first would leave that build running
against instructions changed minutes earlier and never exercised, and you would not know
whether a bad outcome came from the task or the edit.

Read `.claude/learnings/README.md` for the entry format and the bar. Spend **zero engine
launches** — nothing here changes the game.

## What to read, and what not to

Placement is a **global** question — does this rule exist already, which file should own it,
what does it make dead — so a consolidator reading narrowly does not consolidate, it appends.
Appending into the wrong file is how the test sequence ended up in three files with two stale,
and the stale ones were what the agents ran.

But the three surfaces are not read the same way:

- **In force — `CLAUDE.md`, `.claude/agents/*`, `.claude/commands/*`, `settings.json`. Read
  every one, in full, every run.** ~13.6k tokens as of 2026-08-13. This is the surface the
  agents are actually governed by, and the budget to defend: it should come out of a
  consolidation roughly flat, not steadily larger.
- **`pipeline-notes.md` — grep, never read whole.** It is an archive and is meant to grow
  without limit. Search it per entry for one thing: *has this been decided before, and was it
  decided against?* That is what stops a settled trade-off being re-litigated, and it is the
  only question the notes answer during a fold.
- **Hooks and scripts — on demand.** The largest surface and the least often relevant. Open
  them when an entry targets enforcement, and then read the real file rather than reasoning
  about what it probably does.

**If the in-force surface has grown past what you can hold straight, that is the finding.**
The Doer and Reviewer read `CLAUDE.md` on every turn and are expected to act on all of it, so
a consolidator losing the thread is the first honest signal that the pipeline has outgrown the
agents it governs. Report it and cut, rather than reading more selectively and carrying on.

## Change only what an entry justifies

You will finish the reading holding opinions about parts of the pipeline no entry mentions.
**Do not act on them.** An agent with the whole picture and a mandate to improve will
restructure, and the result is a pipeline rewritten every session — each version defensible,
none stable, and the user's familiarity with their own tooling invalidated each time.

The inbox is the bound. Fold entries, and make the deletions those entries license. Anything
else you noticed becomes a **new inbox entry** for next time, with its evidence, and waits its
turn like everything else. Large restructuring needs the user to ask for it, exactly as
`CLAUDE.md` requires for game code.

## Fold each entry as far up this list as it will go

The list is ordered by durability, and the order is the whole point. A rule an agent must
remember is the weakest form of every rule.

1. **Enforcement** — a hook, a test, a permission rule, a `.gitignore` line, a `check_*.py`
   expectation. Executable, fails loudly, cannot be skimmed past, and costs nothing per turn.
   **Always ask for this first.** `.gitignore` keeps 118M out of the repo whether or not
   anybody knows why; a paragraph asking agents to be careful would not have.
2. **`CLAUDE.md`** — for what cannot be enforced. Auto-loaded, so it reaches subagents, and
   paid on every turn of every session by every one of them.
3. **An agent file** — role-specific *judgement* only. It may say which tests to run and how to
   judge them; it may never restate a command. That duplication has gone stale twice here and
   the stale copy was what the agents ran.
4. **`pipeline-notes.md`** — the reasoning, the measurements, the post-mortem. Not auto-loaded,
   so it is free.
5. **Nothing.** A real option. Say which entries you dropped and why.

A single entry often lands in two places: the enforcement *and* one line in the notes saying
why it exists. That is correct. What is not correct is the same rule stated in two files that
both claim to be authoritative.

## Delete as well as add

**This is the half that keeps the pipeline affordable, and it will not happen unless you go
looking for it.** `CLAUDE.md` is re-read on every turn, so text in it is paid thousands of
times; it has already been one of the larger fixed costs in this project once. Each run, check
for:

- **Prose a hook now enforces.** Once a guard exists, the paragraph asking for the behaviour is
  dead weight. Cut it to a sentence naming the guard, or cut it entirely.
- **Rules whose reason has expired** — a trap in a system that was replaced, a workaround for a
  bug that is fixed.
- **The same rule in two places.** Keep the one that reaches the reader who needs it.
- **History that drifted back into `CLAUDE.md`.** Rules there, reasoning in the notes.

Report the **size of the in-force surface**, and quote what the script printed rather than
what you remember writing:

```bash
python .claude/scripts/check_surface.py                     # measure and diff
python .claude/scripts/check_surface.py --record "fold 6"   # ...and bank it, once done
```

It prints `SURFACE: <old> → <new>, <delta>` plus the per-file split against the last banked
fold. **Take the reading before you write the notes section, not after.** Fold 3 wrote its
figure into the notes from memory first — "+16", against a measured **+801** — wrong in
magnitude, wrong in sign on its load-bearing half, and wrong in the flattering direction.

That number going up every run is the mechanism failing slowly, in the one way that is
invisible from inside any single run. A consolidation that only ever adds is not working.

## Then

- **Empty the inbox.** Every entry is folded and deleted, or dropped and deleted. An entry left
  behind will be re-read every future run.
- **Say what you changed**, entry by entry: where it landed, and why not one rung higher. If
  something wanted enforcement but you wrote prose instead, say so plainly — that is the gap
  worth seeing.
- **Do not commit.** That stays the user's call.

If `.claude/learnings/` holds nothing but `README.md`, say so and stop. An empty inbox means
the runs since the last fold taught nothing, which is the ordinary case and not a failure.
