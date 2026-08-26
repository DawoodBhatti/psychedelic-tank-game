# A behaviour-preserving gate's "before" has exactly one chance, and the brief names it too narrowly

- date: 2026-08-26
- surfaced-by: orchestrator
- run: /build session B - LevelDef, LevelRunner, SDFComposite
- target: agent-file

**Evidence.** Session B's gate was "nothing visibly changes". The `/build` brief named three
quantities to capture before any edit: `chunks_total`, `terrain_triangles`, and
`surface_height_range()`. The Doer captured those three, and before/after came back identical.

The refactor then moved `spawn_clearance` out of a `main.gd` export and into `LevelDef`.
`tank_spawn_height` is the harness-facing property derived from it
(`surface_height(0,0) + spawn_clearance`), so it sat directly downstream of a value the change
relocated — and it was not in the before batch. The Doer's own report:

> `tank_spawn_height` has no true BEFORE value — my omission from the first batch, and
> unrecoverable. It reads 4.0 [...] which is self-consistent [...] But it is an inference, not
> a measured pair.

It reconstructed the number from two other measurements and said plainly that it had. That is
the correct handling of the gap, and the gap should not have existed: the brief (mine) chose
the list, and it chose it before anyone knew which properties the refactor would touch.

The cost of having captured all of them was zero. `--harness-eval` is repeatable and CLAUDE.md
already says to batch every question into ONE launch; eight names in that batch is the same
single engine boot as three. There were eight harness-facing names to sweep, all enumerated in
`docs/foundation-plan.md` § Harness surface and in `main.gd`'s own header.

**What it suggests.** Unlike an ordinary measurement, a "before" cannot be re-taken — the first
edit destroys it permanently, and no later launch recovers it. So the selection rule should not
be *what the task seems to be about*; on a behaviour-preserving gate it should be **every
harness-facing name the project exposes, swept in the one batch, because the marginal cost of a
name is an expression and the cost of omitting one is that it can never be measured**. Worth a
line in `.claude/commands/build.md` or `doer.md`: when the gate is "identical", the before
batch is the full harness surface, not the subset the brief enumerates. The brief writer is the
party least able to predict which property a refactor will end up touching.
