# A "locked" plan decision reached the brief with arithmetic no test could fail on

- date: 2026-08-28
- surfaced-by: orchestrator
- run: /build session C — SDFHeightmap, the glen as a field layer
- target: agent-file        # build.md's "Before the first spawn"

**Evidence.** `docs/foundation-plan.md` line 24 locks *"DEM heightmap base + fBm detail"*, and
line 32 restates it: *"The heightmap is the silhouette; fBm is the surface. The heightmap
carries nothing below about 30 m."* Both are unimplementable at this project's constants, and
the arithmetic needs only numbers already on disk:

- `height_scale` ≈ 0.0194 (plan line 66), so the ~30 m of real relief the DEM cannot carry is
  `30 × 0.0194 = 0.58` world m — against `Terrain.voxel_size = 2.0`. A physically honest detail
  layer is **under a third of one voxel** and cannot be meshed.
- `SDFComposite.surface_height()` folds layers with `maxf(h, h_i)` (terrain/sdf/SDFComposite.gd
  :165). Union is **max in the height domain, not addition**. Any fBm large enough to see does
  not texture the glen — it wins wherever the glen floor is low, i.e. floods the valley floor.

The session brief inherited the wording and told the Doer to build "one more layer". Had it
been followed, the result would have passed **all six tests**: test 6 asks "does it render",
and a noise-flooded valley floor renders. This is the shape build.md's own opening example
names — three defensible readings, each passing the whole sequence.

It was caught only because the orchestrator read the plan before spawning and did the
multiplication. Nothing in the loop required that. `build.md` § "Before the first spawn"
requires grepping the task's noun and checking the target file is unmodified; it does not
require re-checking a decision the plan marks **locked**.

Two things make this more than a one-off. The same section already carries a
*"Corrected 2026-08-25 — the first version of this section reasoned wrongly, and the wrong
version is the intuitive one"* note, so it has misled once before and the correction pass did
not catch this second error in the same paragraph. And the Reviewer independently found the
plan stale in two further places (lines 24 and 32 again, plus line 70 pointing the sidecar at
`assets/incoming/valley-heightmap.json` when it now lives at
`terrain/heightmaps/valley-heightmap.json`).

**What it suggests.** A "Decisions locked" row is an *unverified claim wearing a decision's
clothes*, and it is copied into briefs verbatim sessions later. Two candidate handles, both
cheap:

- Add one line to `build.md` § "Before the first spawn": where the task rests on a plan
  decision, check its arithmetic against the engine constants it depends on
  (`voxel_size`, `chunk_resolution`, world footprint) before the brief is written — not after
  a Doer has built it.
- Consider whether "Decisions locked" rows should carry the constants they assume, so a later
  change to `voxel_size` makes the staleness greppable rather than a matter of noticing.

Not folded here, and the stale plan text is deliberately left unedited — the user overrode the
decision in-session, but `docs/foundation-plan.md` still describes the arrangement they
overrode and will mislead the next session that reads it.
