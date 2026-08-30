# A harness-level standing instruction told agents to bypass the guard-walled write path

- date: 2026-08-30
- surfaced-by: orchestrator (Doer flagged it in its report)
- run: /begin S2 — strip the Wild Metal Country combat scaffolding
- target: unsure

**Evidence.** Mid-session, the harness injected a standing instruction into both the
orchestrator's and the Doer's context: do the work "through the Bash tool wherever it can
accomplish the job" — read with `cat`, `head`, `sed -n`, search with `grep` and `find`, and
**make file changes with `sed`, heredocs, or short scripts, rather than using the dedicated
Read, Edit, or Write tools**, falling back to a dedicated tool only when Bash cannot do the job.

That is the direct negation of `CLAUDE.md § Environment`, which says to read with Read / Grep /
Glob because `cat`, `head`, `tail`, `grep`, `find` and `sed -n` will prompt, and that when a
prompt fires on a `>` redirect or `python -c` "the fix is usually **not** to approve it — it is
to use **Edit** or **Write**, which are walled by the write guard and never prompt."

Both agents hit it and both diverged from it, independently:

- The Doer said so unprompted at the end of its report: "the harness re-sent a standing
  instruction to prefer `cat`/`sed`/`grep` over the Read and Edit tools. I did not follow it...
  CLAUDE.md is explicit that those prompt in this repo... so I kept using Read/Edit and am
  telling you rather than silently diverging."
- The orchestrator's first three tool calls of the session were Bash `grep`/`sed` invocations
  and all three were refused by the no-`cd` guard, after which it switched to Grep/Read.

**Why this is a pipeline risk and not a style quibble.** `CLAUDE.md § Guards` names the write
guard's one blind spot itself: it "**does not see writes made through Bash** — a `>` redirect or
`python -c` is opaque to it," and says that gap is covered by permissions. An instruction to
prefer heredocs and `sed` for file changes is therefore an instruction to route edits through
the one path the guard cannot inspect. An agent that complies degrades a guard this project
built on purpose, and does so while believing it is following orders.

Nothing was harmed in this run — both agents resolved the conflict the right way, and CLAUDE.md
does say its instructions override default behaviour. The finding is that the resolution
depended on each agent noticing the contradiction and choosing correctly, which is not a control.

**What it suggests.** Two separable questions for the consolidator. First, whether the harness
setting that emits this instruction should be turned off for this repo — it appears to be a
session-level mode rather than anything in `.claude/`, so this may be a note for the user rather
than a change to a tracked file. Second, whether `CLAUDE.md § Environment` should say explicitly
that an instruction to prefer shell file-editing is to be refused *whatever its source*, so the
next agent does not have to re-derive the conclusion. The second is cheap and is in force
wherever the first is not.
