# Roadmap

The ordered backlog. **`/begin` reads this file, runs the next `todo` session, and writes the
result back here.** One session per `/begin`, because the budgets in `CLAUDE.md § Budgets` are
per session and never reset.

This file is the state. Not the conversation, not an agent's memory — the disk. A session that
dies mid-task leaves a `resume:` note here and the next `/begin` picks it up.

`docs/foundation-plan.md` is the *design* contract and still governs the layer architecture.
Where the two disagree about **what to build next**, this file wins; where they disagree about
**how the code is shaped**, that one does.

## Status vocabulary

| status | meaning |
|---|---|
| `todo` | ready to run, dependencies met |
| `in-progress` | a session started it and did not finish; read `resume:` |
| `blocked` | needs something `/begin` cannot do; read `blocked-on:` |
| `done` | gate met and recorded, work committed |

Read it with `.claude/scripts/roadmap.sh` — no engine launch, and it prints the next runnable
session.

---

## S0 — Baseline commit
- status: done
- gate: tree clean, tests 1 and 2 green
- landed: 2026-08-29. Committed the previous session's finished-but-uncommitted work — the
  glen widened 192→384 at `height_scale` 0.04→0.08, grid 4×2×4→8×3×8, and
  `Terrain.destructible` defaulted off. Verified before committing: `script_errors=0`,
  `check_resources PASS {"checked":12,"failed":[]}`, load 4.404 s. Recorded so every later
  before/after number has an obtainable baseline.

---

## S1 — Feel pass: recoil, aim coupling, contour lines
- status: done
- depends: S0
- landed: 2026-08-29, Reviewer-verified. **Recoil** 4.0 → 2.0, read 2.0 off the live node;
  `fire()`'s recoil line untouched. **Camera coupling** `-barrel_pitch * 0.6 - 10.0` →
  `barrel_pitch * 0.6 - 5.0`: camera forward Y **−0.2113** at `barrel_pitch` −12 and **+0.3453**
  at +42, so the view now rises with the gun — while `_apply_aim()` is untouched and the muzzle
  still follows the mouse (forward Y −0.208 on mouse-down, +0.669 on mouse-up), which is the
  half that says the *wrong* fix was not made. **Contours** added to the shader **and** the
  material: the `.tres` overrides every one of those uniforms, so editing the shader alone would
  have been dead code. Live read off the rendering chunk: `contour_strength 1.8`,
  `contour_interval 4.0`, `contour_index_every 5.0`, `contour_color (1.0, 0.62, 0.16)`,
  `emission_strength` 2.4 → 1.6, `line_width` 0.045 → 0.035. Banding confirmed against a
  constructed zero — a sky region moved `delta.luma_mean +0.3` and `delta.hue_frac.grey 0.0000`,
  so there was no global exposure change — with 40 horizontal strips at y 0.70–0.80 giving
  `delta.luma_mean` +11.1 → +28.8 on a ~29 px period and `delta.hue_frac.grey` +0.238 → +0.684
  **in phase**, and troughs reaching −0.7 at y 0.56–0.64. Tests 1–6 pass; fps min 107 avg 118.6,
  load 4.702 s, `check_resources PASS {"checked":12,"failed":[]}`, zero errors and zero warnings.
- unverified: **the camera at full elevation.** At `barrel_pitch` 42 the uncollided `Camera3D`
  sits 1.79 m *below* the hull origin. The SpringArm (mask 1, margin 0.5) pulls it in, so the
  view collapses toward the turret rather than clipping into rock — but the harness cannot drive
  input and `--harness-shot` renders an explicit pose, not the game camera. Needs thirty seconds
  of hands at full elevation. If it reads badly, the dial is the `0.6` coefficient.
- also unverified: the mouse binding itself. `--harness-eval` cannot reach `Input`, so that
  mouse-up yields a negative `relative.y` is read off the code rather than measured. Both agents
  called `_apply_aim()` directly, which is what `CLAUDE.md § The dev harness` says to do here.

Three small, independent changes. Bundled because each is minutes of work and a session's
budget is 40 launches. This is also the session that proves `/begin` works end to end, so keep
it boring.

**1. Halve the recoil.** `tank/tank.gd`, `@export var recoil: float = 4.0` → `2.0`. Applied as
`velocity += muzzle.global_basis.z * recoil` in `fire()`. One number, one line.

**2. The vertical aim is not inverted — the camera is.** Read this before touching anything,
because there are two defensible fixes and one of them is wrong.

`_apply_aim()` does `barrel_pitch = clampf(barrel_pitch - dy, PITCH_MIN, PITCH_MAX)`. Mouse-up
gives a negative `relative.y`, so `barrel_pitch` **rises**, and a positive X rotation on the
barrel points it up. **The gun already follows the mouse correctly.**

The inversion is one line down, in `_aim()`:

```gdscript
camera_arm.rotation_degrees.x = -barrel_pitch * 0.6 - 10.0
```

The `SpringArm3D` holds the camera along its local +Z and the camera looks along its local −Z,
so the camera's forward Y is `sin(arm_pitch)`. With the negation, raising the gun from 8° to 42°
drives the arm from −14.8° to −35.2° and the camera looks *further down* — the horizon rises on
screen while the gun rises, which is what reads as inverted.

Fix the coupling, not the mouse. Do **not** flip the sign in `_apply_aim()`: that makes mouse-up
depress the gun, which is the opposite of what was asked and passes every test.

Target shape: `camera_arm.rotation_degrees.x = barrel_pitch * 0.6 - 5.0`, then tune the
constants against the two measurements below. The arm masks layer 1, so it pulls in against
terrain rather than clipping when the camera swings low.

**Measure it, do not read it off the diff.** One eval batch, setting the pitch through
`set()` because `--harness-eval` cannot assign:

```
scene.tank.set('barrel_pitch', -12.0)
scene.tank._aim(0.0)
scene.tank.camera_arm.global_basis.z.y
scene.tank.set('barrel_pitch', 42.0)
scene.tank._aim(0.0)
scene.tank.camera_arm.global_basis.z.y
```

The camera looks along −Z, so forward Y is `-global_basis.z.y`. The gate is that it **rises**
between the two: gun down → camera looks down, gun up → camera looks up.

**3. Contour lines.** `terrain/shaders/neon_terrain.gdshader`. Keep the triplanar grid — it is
what shows surface shape — and add map-style elevation contours on top, so height reads at a
glance instead of only in the hue ramp.

Iso-lines from world Y only, antialiased by the screen-space derivative the way `grid_line()`
already is, with index contours every fifth line carrying more weight:

```glsl
float contour_band(float y, float interval, float width) {
    float f = y / interval;
    float d = abs(fract(f) - 0.5);
    float fw = fwidth(f);
    // Fade out where the lines bunch tighter than they can be drawn - on a near
    // vertical face the spacing collapses and un-faded contours read as noise.
    return smoothstep(width + fw, width - fw, d) * (1.0 - smoothstep(0.35, 0.5, fw));
}
```

New uniforms, all with defaults that work unattended: `contour_interval` (world units between
minor lines — start at 4.0, one voxel-pair, so the lines sit on the facets rather than beating
against them), `contour_width`, `contour_strength`, `contour_index_every` (5), and
`contour_color`. Fold into `EMISSION` alongside the grid, and give index contours a brighter
multiplier.

Then dial the grid back — the note is that the white grid reads "too basic", so contours should
carry the shape and the grid should sit under them rather than compete.

**`contour_interval` is retuned in S3**, where the world's vertical relief goes from ~68 units
to a few hundred. It is a uniform, so that is a number and not a rework — but leave it exposed
and do not bake it into the shader body.

**Visual gate.** Shoot the same pose before and after and pass the before shot as `--control`,
per `CLAUDE.md § Testing requirements` test 6. Contours add bright horizontal banding to sloped
ground, so pick a region that is all hillside and expect `delta.luma_mean` to rise; judge on hue
as well as luma, never one channel.

---

## S2 — Strip the Wild Metal Country combat scaffolding
- status: todo
- depends: S1
- gate: tests 1–6 green; no dangling `ext_resource` or orphan `.uid`; every harness value on
  `main.gd` unmoved except the spawn counters, which go to zero against an empty manifest.

Deletion only. Nothing is added, which is what makes it cheap to verify and worth doing before
anything is built on top.

**Goes:**
- `entities/enemy_body.gd` (+ `.uid`), `entities/guardian_placeholder.tscn`,
  `entities/profiles/guardian_hull.tres`, `entities/prop_placeholder.tscn`
- The `Group_guardians` and `Group_props` sub-resources and their `PlacementRule`s in
  `levels/valley.tres`, and the two `ext_resource` lines they use
- `CollisionLayers.PICKUPS` and `CollisionLayers.TRIGGERS` — power cores and the collection
  gate are cancelled, so a reserved bit for them is dead numbering. `PLAYER_SHELLS` and
  `ENEMY_SHELLS` **stay** reserved; shells are still raycasts and something may yet need to
  detect one.
- `docs/foundation-plan.md`'s sessions E–H rows, the core-retrieval decision, the cores/gate
  rows in the placement and mask tables, and the `core_collected` / `core_delivered` /
  `objective_changed` / `level_complete` entries in the bus contract. Replace with a pointer
  to this file.

**Stays**, because S4 needs it: `Damageable`, `DamageProfile`, `SkinSlot`, `Spawner`,
`TerrainAnalysis`, `PlacementRule`, `SpawnGroup`.

**Watch for:** `.uid` files are tracked and Godot regenerates them, so delete the pair.
`levels/valley.tres` numbers its `ext_resource` ids by hand — removing two means the rest still
have to resolve. Test 2 walks every resource in the project and is the check that they do.

---

## S3 — The big world
- status: todo
- depends: S2
- gate: the world is at least 2000 units across and drivable end to end; load under 10 s;
  test 4 fps minimum at or above 60; **the visible ground and the collidable ground agree** —
  20 downward raycasts against `field.ground.surface_height()` at the same x/z, worst
  disagreement under 0.5 units; ground visible at the horizon in a region check, not sky.

**What is actually wanted:** a huge glen to drive around. Not more data — the whole 2022 × 2010 m
crop is already loaded; `SDFHeightmap.world_size` squashes it onto a 384-unit footprint at
5.3:1. At the tank's terminal speed of ~21.7 m/s (26 drive against 0.055 drag; ~35 boosting)
that is **18 seconds to cross the entire world.** Mapped 1:1 it is 2000 units, 27× the area,
**92 seconds to cross** and about two and a half minutes corner to corner.

**Why the renderer has to change first.** Marching cubes meshes a *volume*, so cost is cubic in
world width. Measured: 384 × 144 × 384 at `voxel_size` 2.0 is 2.65 M voxels and 4.4 s. At 2000
units it is ~250 M voxels. It is also paying a 3D price for 2D data — `SDFHeightmap.sample()` is
`p.y - surface_height(x, z)`, which has no overhangs by construction — and destruction is off,
so nothing is currently buying what the volume representation costs.

### The approach: a geometry clipmap

Concentric square rings of flat grid mesh, centred on the player. The innermost ring has small
quads; each ring outward doubles the quad size and so covers four times the area. A **vertex
shader** samples the heightmap texture and displaces each vertex to its height. The mesh is
built once and never rebuilt — the rings slide with the player, snapped to their own grid so
vertices never swim between cells.

Cost is fixed regardless of world size. Concretely: **6 levels, 64×64 quads each, base spacing
2.0** covers a 4096-unit radius in roughly 30 k triangles — against 95 k triangles for today's
384 units.

**Build it as `terrain/heightmap/heightmap_terrain.gd` + its own shader.** Do not extend
`terrain/terrain.gd`; that node's contract is a voxel grid and this is not one.

**Four things this has to get right.**

1. **One source of truth for height.** The vertex shader and the collider must produce the same
   surface, or the tank drives on ground nobody can see. Both derive from `SDFHeightmap`'s
   mapping — pass `elevation_min_m`, `elevation_range_m`, `datum_elevation_m`, `height_scale`,
   `vertical_offset`, `world_size` and `world_centre` to the shader as uniforms rather than
   re-authoring the arithmetic. The gate above is exactly this check and it is the one that
   matters.

2. **Collision via `HeightMapShape3D`**, Godot's built-in, fed from
   `field.ground.surface_height()` on the CPU. It is a regular grid of floats with unit spacing,
   so scale the node to set the pitch. Start at 2.0 units — matching today's `voxel_size`,
   against a 4.2-unit-long tank — and one shape for the whole world: 1000 × 1000 samples is 4 MB
   and Jolt is fine with it. Only reach for a moving window around the player if that measures
   badly.

3. **Height scale moves with width or the glen flattens.** `max_world_gradient` reads 1.89054
   today and is dimensionless, so widening 384 → 2000 (×5.208) without touching `height_scale`
   divides every slope by 5.208 — "the same glen, flatter". Holding the gradient means
   `height_scale` 0.08 → ≈0.4167 and about 365 units of relief. That is the arithmetic; whether
   it *feels* right is for the eye, and it is now a cheap dial rather than a cubic-cost
   decision. Re-measure `max_world_gradient` after and expect it back near 1.89.

4. **Retune `contour_interval` with the rest.** S1 shipped it at 4.0 against a measured
   `field.ground.vertical_extent()` of **49.06** (relief span ~68 units), which gives roughly 12
   minor and 2–3 index lines across the whole glen. Multiply it by whatever `height_scale` is
   multiplied by, or the new relief arrives carrying several hundred lines and reads as a wash.
   It is a uniform on `terrain/materials/neon_terrain.tres`, so this is a number, not a rework.

5. **Retune what assumed a small world.** `fog_density` 0.0022 gives ~450 units of visibility
   and would hide the new horizon; `directional_shadow_max_distance` is 320. Camera `far` is
   already 3000 and needs nothing. Beyond the raster's edge `SDFHeightmap` extends the edge
   value, so the outermost ring runs to flat ground at the horizon rather than to void — which
   is the "still in the world" illusion, for free.

**What happens to marching cubes.** It stays, unused, moved to `terrain/voxel/`. Destruction is
deferred, not cancelled, and Wild Metal Country's terrain deformed — when it comes back it comes
back as a local patch around a crater, not as the way the world is represented. Test 2 keeps
walking it, so it cannot rot silently. `main.tscn` stops instancing it.

**Known limitation, state it and move on.** NASADEM is 1 arcsec — about 17 m east-west and 31 m
north-south at this latitude. At 1:1 that is one real sample every ~30 units against a 4.2-unit
tank, so the glen will be correct at the scale of ridges and valleys and smooth at the scale of
the vehicle. **Size and detail are separate problems and a bigger crop only fixes size, which is
not the one that is left.** Detail means procedural noise on top, or a finer source; both are
deferred, and the noise route needs the `maxf` trap below solved first.

**Not in this session:** geomorphing across ring boundaries. Naive clipmap LOD pops when a ring
changes level. Measure whether it is visible at this speed and scale before spending anything on
it — it may not be.

---

## S4 — Destructible towers
- status: todo
- depends: S3
- gate: five shells destroy one tower and four do not, driven through the harness on the live
  node; the crack parameter moves at the authored thresholds; `collision_layer` and
  `collision_mask` re-measured off every live tower body.

**What is being built:** a few simple towers scattered on the glen that visibly crack as they
take tank shell hits and die on the fifth.

**After S3 on purpose.** Placement rules are thresholds against measured terrain quantiles, and
`entities/PlacementRule.gd`'s header says every one of them must be re-derived when the ground
field changes. Authoring them before the world triples in scale means tuning them twice.

This is the first change that makes a shell *do* something, so it is bigger than it looks.
`tank/shell.gd` masks `CollisionLayers.TERRAIN` only and applies no damage at all — it emits
`shell_exploded` and frees itself.

**1. Shells carry damage.** Add `@export var damage: float = 20.0` and
`@export var damage_type: int = DamageProfile.Type.KINETIC`. In `_detonate()`, before emitting,
look for a `Damageable` on the collider (`hit["collider"]`) and call `apply_damage()`. Widen
`hit_mask` to `TERRAIN | STRUCTURES`.

Rename `CollisionLayers.ENEMIES` to `STRUCTURES` in the same pass — nothing fights back any
more, and a bit named for a thing that does not exist is how the numbering rots. The bit value
is unchanged (`1 << 3`); it is the name that moves. `tank.gd` masks it, so both move together.

**2. `entities/tower.gd` + `entities/tower.tscn`.** A `StaticBody3D` with a `CollisionShape3D`,
a `SkinSlot` holding placeholder geometry, and a `Damageable` carrying
`entities/profiles/tower.tres`.

Five hits means `max_health = 5 × shell damage` **derived, not hardcoded twice** — author the
profile at 100.0 against a 20.0 shell and say so in one place. Nothing enforces the arithmetic;
the gate is what checks it.

**3. Visible cracking.** The tower's material takes a `damage_amount` uniform, 0..1, written
from `Damageable.health_fraction()` on the local `damaged` signal — local, not the bus, because
a tower reacting to its own damage is a parent-child relationship (`CLAUDE.md § Code
standards`).

Quantise to stages rather than ramping continuously, so the player can count hits:
`floor((1.0 - health_fraction()) * hits_to_kill) / hits_to_kill`.

**Do not read the crack state back off the material to prove it works** — that is re-reading
what the change just wrote. Read `damageable.health` and the tower's own stage var, derived
differently, and confirm the visual separately with a region check on a screenshot.

**4. Author them into the level.** One tower group in `levels/valley.tres`, replacing the groups
S2 deleted. Its `PlacementRule` bounds sit between measured quantiles from
`TerrainAnalysis.metrics_summary()` on the **post-S3** field. Publish the new quantiles in the
`PlacementRule.gd` header the way the existing ones are.

**5. Harness surface.** `towers_alive` and `towers_total` on `main.gd`, as computed getters off
the live nodes, never mirrored per frame. `main.gd` already has `enemies_alive` /
`enemies_total` doing exactly this against `Spawner.live_damageable_count()` — rename rather
than add.

**The gate, precisely.** Four `apply_damage(20.0)` calls leave `is_alive` true and
`towers_alive` unmoved; the fifth flips both. Both halves matter — a tower that dies in three
hits passes a test that only checks it dies.

---

## S5 — Hand-authoring affordance
- status: todo
- depends: S4
- gate: a tower placed by hand in `main.tscn` at an authored x/z appears there, snapped to the
  ground, with `min_ground_clearance` still positive across authored and scattered entities
  together.

The point of the whole project: systems built by the pipeline, content placed by you.

Today everything is scattered by rule. `Spawner.scatter()` matches `PlacementRule`s against
`TerrainAnalysis` metrics, which is right for filling a valley and wrong for "I want a tower on
*that* ridge".

Add authored placement alongside it, not instead of it:
- An `AuthoredPlacement` resource — scene, x/z, yaw, and whether to snap to the surface — as an
  array on `LevelDef`, placed before the scatter so authored entities reserve their ground the
  way `_place_tank()` already does.
- A node-marker path too, for dragging things in the editor: any child of a known group gets
  ground-snapped on load rather than needing its y typed in.

Then write `docs/authoring.md`: how to drop a `.glb` into a `SkinSlot`, how to add a tower, how
to place one by hand, which numbers are safe to change and which are load-bearing. Short, and
aimed at doing it without a session.

---

## S6 — Refactor and comment compression
- status: todo
- depends: S5
- gate: **nothing visibly changes.** Every harness value on `main.gd` bit-identical before and
  after, captured in one batch before the first edit — that batch is the whole surface, not the
  part the task looks like it is about.

Agreed 2026-08-29: **compress in place, archive the rest.** Each file keeps a short what/why
header in ordinary prose. The archaeology — measured numbers, superseded reasoning, the
post-mortem of a bug that no longer exists — moves to `docs/design-notes.md`, one section per
file, linked from the header it came from. Nothing is deleted; it stops being in the way.

Ratio today is roughly 3–5 lines of comment per line of code. `terrain/sdf/SDFHeightmap.gd` is
459 lines carrying maybe 120 of implementation.

**What stays in the code, always:** a number that was measured and would otherwise be re-guessed;
a sign convention (`negative is inside`); a collision layer; an ordering that is load-bearing
(`Terrain._ready()` before `LevelRunner._ready()`). Those are contracts, not history.

**What moves:** reasoning that was corrected, before/after numbers from a change that has landed,
and any paragraph explaining why something is *not* built.

Also in scope: dead code, redundant systems, and any pattern that exists in two places. Do not
introduce a new convention for something an existing one covers.

**This session's gate is why it comes last.** "Nothing changes" is only checkable while the
systems underneath are settled, and it is the cheapest possible gate once they are.

---

## S7 — Extractability
- status: todo
- depends: S6
- gate: a scene containing only the terrain node and its field loads, builds and reports
  non-zero geometry with no `LevelRunner`, no `GameEvents` and no autoloads beyond the logger.

Systems that lift into other prototypes. Today `terrain/` reaches for `GameLogger` and
`GameEvents` by autoload name, which means it only runs in this project.

- Terrain emits its own signals; the level relays them to `GameEvents`. The bus is for
  cross-system events, and a chunk telling its own parent it re-meshed is not one.
- Logging goes behind an injected sink or a null default, so a missing autoload is not an error.
- `entities/` gets the same treatment: `Damageable` and `SkinSlot` are already close — they take
  resources and emit local signals — and mainly need the `GameEvents` calls made optional.

Then the folders drop into another Godot project as-is. That is the test, and it is worth
actually doing once rather than asserting.

---

## Deferred

Named so they are not rediscovered as ideas: enemy AI of any kind, scoring, win and lose
conditions, multiple levels, audio, geomorphing across clipmap ring boundaries, terrain that
remembers damage across a reset, GPU marching cubes.

**Terrain detail below ~30 m**, which is the one the glen will visibly want. Two routes, neither
free. A finer DEM source — Copernicus is 30 m too and needs attribution, so this means UK LIDAR
under OGL. Or procedural noise added to the sampled height, which is blocked on
`SDFComposite.surface_height()` folding layers with `maxf` — that is union, not addition, so an
fBm layer wins wherever the glen floor is low and floods the valley floor rather than texturing
it. See `.claude/learnings/2026-08-28-locked-plan-decisions-are-never-rechecked.md`. Under a
heightmap renderer the fix is simply to add rather than union, which is why this gets easier
after S3 and not harder.

**Destruction.** `Terrain.destructible` is off and the machinery is intact. It returns as a
local voxel patch around a crater, composited over the clipmap — not as the way the whole world
is represented.
