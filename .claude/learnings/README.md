# The learnings inbox

Somewhere to put a finding **the moment it is found**, so it survives the session that found
it. Nothing here is in force. Nothing here is auto-applied. `/consolidate` empties it, with a
human present.

This is `model-sources.json`'s split again: **append-only with evidence on one side, a human
moving entries on the other.** An agent that folds its own findings into its own instructions
has no instructions. Same shape, same reason.

## The bar

**Evidence, or it does not go in.** A command and its output, a measurement, a diff, a file
that did or did not exist. "The Doer should be more careful about scale" is not a learning; it
is a mood. `CommonTree_1` measuring 7.265 units when the pipeline assumed unit scale is a
learning.

**Most runs teach nothing, and zero entries is the correct output of a healthy run.** A
`/build` that compiled, passed six tests and shipped has told you your pipeline works. Writing
three findings anyway is the failure this project already refuses in the modeller: asked for a
confident score, a model produces one. Asked what a run taught, it will produce something every
time unless told plainly that empty is the expected answer. It is.

Do not file: anything already written in `CLAUDE.md`; anything that is a fact about the game
rather than about the pipeline; anything you fixed inside the run.

## Who writes

- **Reviewer** — the best-placed *finder*, but **not a writer**: its tool list has no `Write`,
  by design, because it is read-only with respect to source. It ends its run holding the plan,
  the diff, the test output and its own disagreements with the Doer, which is exactly the
  material findings come from — so it puts the entry, in this format, at the end of its report
  and the orchestrator files it verbatim. Same channel as the Doer below, for the same reason.
  Costs no engine launch and no agent turn, because it happens inside the report it was
  already producing.
- **The `/build` orchestrator** — for what it noticed that was never a Reviewer finding.
  Adjacent risks spotted while editing are a real category and the loop has no other home for
  them. **Including anything the Doer flags in its report.** The Doer is not on this list — it
  is mid-task and self-certifies nothing — but it is the role that meets a compile-gate defect
  first, so it says so and the orchestrator files it.
- **The user, or a session doing anything else.** A finding does not need a `/build` to exist.

## One file per finding

`.claude/learnings/YYYY-MM-DD-<short-slug>.md`. One finding per file, so consolidating one does
not mean rewriting a shared document, and so an unfolded backlog is countable at a glance.

```markdown
# Godot imports every format a pack ships, not the one you want

- date: 2026-08-13
- surfaced-by: orchestrator
- run: /build foliage on the grass islands
- target: config          # hook | test | config | claude.md | agent-file | notes | unsure

**Evidence.** The Quaternius MegaKit unzips to 118M carrying the same 68 models as glTF, OBJ,
FBX and FBX (Unity). `find assets -name "*.import"` returned 0 before the fence went in;
without it Godot would have walked ~300 import records to reach 14 usable models.

**What it suggests.** A `.gdignore` in the staging folder, written before the next engine
launch. Prevention is one empty file; cleanup afterwards is stale `.import` entries plus a
`.godot/` rebuild.
```

`target` is a **guess for the consolidator, not a decision.** `unsure` is an honest value and a
better one than a confident wrong guess.

## What happens to an entry

`/consolidate` folds it and deletes it, or judges it not worth folding and deletes it. Either
way it leaves. The inbox is a queue, not an archive — the reasoning that survives folding lives
in `pipeline-notes.md`, and the entry's own history is in git.
