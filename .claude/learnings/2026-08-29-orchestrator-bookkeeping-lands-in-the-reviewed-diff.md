# /begin's own status write lands in the diff the Reviewer scope-checks

- date: 2026-08-29
- surfaced-by: orchestrator
- run: /begin S1 — feel pass: recoil, aim coupling, contour lines
- target: agent-file        # begin.md, and possibly reviewer.md

**Evidence.** `.claude/commands/begin.md` § 3 tells the orchestrator to flip the roadmap
entry's `- status: todo` to `in-progress` **before the first spawn**, so a session killed at the
budget wall leaves a trace. That write is uncommitted state, so it is in the working tree for the
whole run and shows up in `.claude/scripts/diff.sh`.

Both agents had to account for it. The Doer's report ended:

> (`docs/roadmap.md` is also dirty — the orchestrator's `status: in-progress` flip, not mine.)

and the Reviewer's scope check had to enumerate it as an exception:

> Scope matches: `.claude/scripts/diff.sh` touches only `tank/tank.gd`,
> `terrain/shaders/neon_terrain.gdshader`, `terrain/materials/neon_terrain.tres` and the
> `status:` line in `docs/roadmap.md`.

It was harmless here only because the Doer volunteered the explanation. Nothing in `doer.md`,
`reviewer.md` or `begin.md` says the file will be dirty or who dirtied it, so the next Doer that
does not mention it leaves the Reviewer holding an unexplained out-of-scope edit to the file that
defines the task it is reviewing — which is exactly the shape a Reviewer should be suspicious of.
This run was the first ever use of `/begin`, so there is no second data point.

**What it suggests.** One sentence in `begin.md`'s § 3 telling the orchestrator to state in the
Doer's brief that `docs/roadmap.md` is already dirty and is not theirs to touch, and the same in
the Reviewer's. Cheaper than the alternatives — committing the status flip as its own commit
before spawning (an extra commit per session, and it would have to be amended or reverted when
the session does not finish), or keeping the in-progress marker somewhere other than the roadmap
(which splits the state that the file exists to hold).
