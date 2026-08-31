# CLAUDE.md is auto-loaded by three readers and parts of it are addressed to only one

- date: 2026-08-31
- surfaced-by: consolidator (fold 3)
- run: /consolidate
- target: claude.md

**Evidence.** `CLAUDE.md` is re-read on every turn of every session by the orchestrator, the
Doer and the Reviewer. Several of its sections can only be acted on by the orchestrator, and
the other two readers pay for them on every turn:

- `§ The loop` carried ~840 characters of agent-resumption procedure — recover from disk,
  restate what was measured, when to open an `.output` transcript. The Doer and Reviewer have
  no `Agent` or `SendMessage` tool and cannot resume anything. Fold 3 cut it to a three-line
  pointer and moved the unique half into `build.md`, with no loss of force: both halves already
  existed in `begin.md § 1` and `build.md § The cycle`. That cut is the measurement — it proves
  the category is real and that removing it costs nothing.
- Still present and in the same category: `§ Scope`'s "Committing is `/begin`'s job and nobody
  else's", `§ The loop`'s roadmap/`/begin`/`/build` routing, `§ Budgets`' "one `/build` per
  session", and `§ Learnings`' description of what `/consolidate` does. Roughly 1.5–2k
  characters, against a file that measured 23319 at the end of fold 3.

Fold 3's own share of surface growth was **+5079 (`CLAUDE.md` +2417)**, the largest of any fold
so far, against a command that asks for roughly flat. One structural cut was available and was
taken; it was not enough.

**What it suggests.** Ask whether the auto-loaded file should carry a role-routed section at
all — the agent files exist and are loaded per role. The cheap version is moving orchestrator-
only text into `build.md`/`begin.md`, which are read by exactly the reader that needs them, and
which fold 3 has now done once as a worked example. Not folded here on purpose: `consolidate.md`
requires an entry to license a change, and restructuring on a consolidator's own opinion is how
a pipeline gets rewritten every session. This entry is that licence for whoever folds next.
