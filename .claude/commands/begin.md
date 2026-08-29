---
description: Run the next session from docs/roadmap.md end to end, then commit and stop.
argument-hint: "[session id, e.g. S3 - defaults to the next runnable one]"
---

Run the next roadmap session. **$ARGUMENTS**

You are the orchestrator, exactly as in `.claude/commands/build.md` — that file is the cycle and
this one does not restate it. What `/begin` adds is where the task comes from, what happens when
it lands, and when to stop.

**The roadmap on disk is the state.** Not this conversation and not an agent's memory. That is
the whole point: you can be killed mid-session and the next `/begin` picks up from the file.

## 1. Pick the session

```bash
.claude/scripts/roadmap.sh
```

Costs no launch. Take the session it names as `NEXT`, unless `$ARGUMENTS` names one — an
explicit id overrides, and running out of order is the user's call, not yours.

- **`blocked`** → report what `blocked-on:` names, say plainly that nothing later is runnable
  either, and stop. Do not improvise around it. If it is blocked on an asset, check whether the
  asset arrived since the note was written before believing it.
- **`in-progress`** → a previous session died in it. **Recover from disk first**:
  `git status --short` and the files it left, whose headers carry their own design contract.
  Read `resume:` for what it had already measured. Then restate the brief *and those
  measurements*, or the Doer re-buys launches already paid for. Do not respawn cold.

## 2. Pre-flight

Three checks, all cheap, all worth it.

1. **Guards.** The session-start line must read `GUARDS: armed (root …)`. Absent means the
   guards are off whatever the config says — stop and tell the user.
2. **Clean tree.** `git status --short`. A `todo` session must start clean, because a change
   already on disk leaves no obtainable "before" at HEAD and every later number describes
   something else. Dirty → stop and ask; usually commit first.
   *An `in-progress` session is the exception* — a dirty tree there is the work being resumed,
   and it is the baseline.
3. **Budget.** `.claude/scripts/budget.sh`. Report the numbers it prints, never a tally.

## 3. Mark it started

Edit the session's `- status: todo` to `- status: in-progress` in `docs/roadmap.md` **before the
first spawn**. A session killed at the wall then leaves a trace instead of looking untouched.

Use `Edit`, not a shell redirect — the write guard cannot see writes made through Bash.

## 4. Run the cycle

Follow `.claude/commands/build.md` from "Before the first spawn" through to its Learnings
section. The roadmap entry is the brief: give the Doer the whole section, including the gate,
because the gate is what the Reviewer will judge against.

Two things the roadmap adds to the brief:

- **The gate is not negotiable and not paraphrasable.** Hand it over verbatim. A gate reworded
  by the orchestrator is the failure `build.md` opens with — the tests check that the code does
  what the *Doer* meant, never that the Doer meant what the *roadmap* did.
- **Where the section says "do not do X", carry that across.** Those lines are there because X
  is the plausible wrong reading, and it usually passes every test.

## 5. When the Reviewer approves

**Commit.** Agreed with the user 2026-08-29: `/begin` commits on a green review, on the current
branch, never pushing, never to `main`. This is what makes the next session's pre-flight pass —
a dirty tree between sessions is what cost this project a baseline once already.

```bash
git add -A
git commit -m "<session id>: <what landed>"
```

Message body: what changed and the numbers the gate was met with. Co-authored trailer as usual.

**Then write the result back into `docs/roadmap.md`**, with `Edit`:

- `- status: in-progress` → `- status: done`
- Replace the `- gate:` line's session with a `- landed:` line: the date, and **the measured
  numbers the gate was met with**. Not "gate met" — the numbers. The next session reads them as
  its baseline, and a gate recorded without its figures is a claim.
- If the session changed what a later one has to do, edit that session too. A roadmap that
  disagrees with the code is worse than no roadmap.

## 6. If the budget wall arrives first

Stop immediately — do not raise the ceiling. Then, before reporting:

- Leave `- status: in-progress`.
- Add a `- resume:` line: what is done, what is left, **and every number already measured**.
  That line is the entire handover. Write it as though the reader has no context, because it
  does not.
- Say in the report whether the tree is dirty and which files.

## 7. Stop

**One session per `/begin`.** The budgets are per session and never reset, so a second one runs
on whatever the first left. Do not start the next session, and do not offer to.

Report per `build.md § Finishing`, plus:

- The roadmap line as it now stands, and what `NEXT` is.
- If the next session is `blocked`, what the user has to do to unblock it. That is usually the
  only thing standing between them and the next run.
- Tell them to `/clear` and `/begin` again. A fresh session is not politeness — it is the
  budget resetting.
