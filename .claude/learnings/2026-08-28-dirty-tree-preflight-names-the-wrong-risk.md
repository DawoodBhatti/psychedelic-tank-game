# The dirty-tree pre-flight names the wrong risk, and one of its two fixes destroys the baseline

- date: 2026-08-28
- surfaced-by: orchestrator
- run: /build lose destructible terrain by default; widen the glen 2x
- target: agent-file

**Evidence.** `.claude/commands/build.md` says, of a file the task will touch that is already
modified:

> A change already on disk from an earlier session leaves no obtainable "before", so every
> before/after number describes something else. Modified → stop and ask; usually commit or
> stash first.

This session opened with `entities/PlacementRule.gd`, `levels/valley.tres`,
`terrain/fields/world_field.tres` and `terrain/terrain.gd` modified, plus `terrain/heightmaps/`
and `terrain/sdf/SDFHeightmap.gd` untracked — Session C's DEM swap, finished but uncommitted.
The task edited three of those four files.

Both halves of the stated rationale were false here:

1. **The "before" was obtainable.** It lives in the WORKING TREE, not at HEAD. One batched
   launch (`log=.../logs/session_20260828_134113_366.log`, 34 expressions) captured all of it
   — `terrain_triangles 23672`, `max_world_gradient 1.89054`,
   `shell_exploded.get_connections().size() 2` — and every later comparison in the run was made
   against those numbers.

2. **"Stash first" would have destroyed it.** HEAD (`8b84b95`) is the *fBm-hills* world;
   the Glen Coe DEM existed only in the working tree. A stashed baseline would have described
   terrain the task was not about, and the widening — whose whole acceptance criterion was
   `max_world_gradient` coming back unchanged — would have been tuned against hills the user
   had already replaced. The rule offers this as one of two co-equal fixes.

The real risk of proceeding dirty was neither: it was that `git checkout` could no longer
separate this task's damage from Session C's ~18 KB of new code and its re-derived placement
bounds. That is an argument for committing, and only for committing.

**What it suggests.** Rewrite the rationale rather than the action. The stop is right; the
reason should be the lost undo boundary, and `stash` should be struck as a suggested fix or
fenced with "only when HEAD is the same world the task is about." Worth adding the positive
step the rule currently omits: capture the baseline from the dirty tree FIRST, since it is free,
it is the one chance, and it is correct regardless of what the user then decides.
