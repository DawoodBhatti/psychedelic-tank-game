# Harness-facing state mirrored per frame reads stale inside a batch

- date: 2026-08-19
- surfaced-by: orchestrator
- run: initial project scaffold (pipeline transplant + core mechanics)
- target: claude.md

**Evidence.** `main.gd` exposed `explosions_spawned` as a plain `var` refreshed from the
effects director in `_process()`. A single batched eval emitted the bus signal and then read
the value back:

```
HARNESS: eval  scene.explosions_spawned = 0
HARNESS: eval  root.get_node("GameEvents").shell_exploded.emit(Vector3(0.0, 0.0, 0.0), 8.0) = <null>
HARNESS: eval  scene.explosions_spawned = 0      <- wrong
HARNESS: eval  scene.terrain.craters_carved = 1  <- right, read straight off the owner
```

The effect *had* spawned. Both listeners on `shell_exploded` ran. But `_cmd_eval` executes
every expression in one pass with no frame in between, so `_process()` never ran to copy the
number across, and the mirror still held its pre-emit value. Read directly off the owning node
in the next launch, the same sequence gave 0 -> 1 -> 2 across two emits.

**Why it is the dangerous shape.** The wrong reading was `0`, against a signal that had fired
correctly - i.e. it reports "the connection is broken" about a connection that works. It looks
exactly like the failure it is not, and the obvious next move is to go and "fix" a correct
signal wiring. Nothing else in the sequence contradicts it: the run compiles, passes resources,
logs no errors, and renders.

**What it suggests.** `CLAUDE.md` § The dev harness already says a launch can mutate the scene
*or* photograph it, never both. This is the same constraint one level down and it is not
written anywhere: **within a single eval batch, no frame runs**, so anything whose value is
produced by `_process`, `_physics_process`, a `Timer`, or a tween is frozen at its pre-batch
value for the whole batch.

The fix that removes the class rather than the instance is to expose harness-facing state as a
computed getter rather than a mirrored var - it cannot be stale, and it costs nothing when
nobody reads it. That is now what `main.gd` does, and the comment there explains why. Worth one
line in `CLAUDE.md` under the harness section; the Doer guidance about "expose the computed
value as state" currently reads as an endorsement of exactly the mirror that failed here.
