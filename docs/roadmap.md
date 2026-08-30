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

## S1b — Camera height, and the contour flicker on the valley floor
- status: done
- depends: S1
- landed: 2026-08-30, Reviewer-verified. **Camera height moved to the pivot**, not the pitch —
  `CameraArm` y 1.4 → **4.2** in `tank.tscn` (pivot 5.5 = Turret 1.3 + arm 4.2), with
  `CAMERA_PITCH_FOLLOW` 0.6 and `CAMERA_PITCH_BIAS` −5.0 named as separate constants and the
  coupling line reading `barrel_pitch * FOLLOW + BIAS`. Resting height above the tank
  **2.745 → 5.545** (direct `Camera3D` read; Reviewer reproduced 5.5453782 independently),
  **8.247** at `barrel_pitch` −12 and **+1.011** at +42 — the last two derived from the arm
  transform on a formula that agrees with the direct read to eight figures at rest. Both
  forbidden dials confirmed unmoved: bias still −5.0, follow still 0.6, so the height was not
  bought by re-biasing pitch. **S1's open item is closed**: at full elevation the uncollided
  camera was 1.79 m *below* the hull origin and now sits **1.011 above** it.
  **The flicker was cause (a)** — flat ground collapsing `fwidth` to zero — identified by
  measurement before the fix. Chunk normals are flat per triangle, and the valley floor's
  `1 - |n.y|` measures **0.0000** (three facets literally constant in world Y, so `fwidth` is
  exactly zero and the facet flips as a whole) up to 0.0036, against hillsides **0.0140–0.2295**.
  (b) was ruled out on its own premise: a minor line emits luminance ≈1.20 against a 0.85 glow
  threshold *everywhere* in the frame, so the floor's dark albedo cannot be what puts it at the
  threshold. Fix is `contours *= smoothstep(0.003, 0.012, 1.0 - abs(n.y))`, consts not uniforms,
  thresholds set between the two measured populations; `contour_width` 0.05 and
  `contour_strength` 1.8 both untouched. Flat-vs-sloped at one pose, both channels: flat slab
  **Δluma −22.8 / −27.9 and Δgrey −0.599 / −0.629**, sloped bands **Δluma 0.0 and Δgrey 0.0**,
  and the slopes still carry S1's contours (+4.8 luma / +0.074 grey against the pre-contour
  frame, versus S1's own +4.9 / +0.074). Tests 1–6 pass; fps min **118.0** avg 119.8, load
  **4.371 s**, `check_resources PASS {"checked":12,"failed":[]}`, zero errors and zero warnings.
- unverified: **framing, and the flicker symptom itself.** The flicker is temporal and one frame
  cannot show it — the mechanism was measured, not the symptom, so the user confirms by eye.
  Framing is unverifiable with the supported tooling: `--harness-shot` replaces the camera with
  an explicit pose, so the game camera cannot be photographed. One number for the eye: from the
  measured pose the hull origin sits **22.9° below the view axis** (turret centre ~16°) against a
  72° vertical fov, so the tank is in frame roughly 64% of the way down. Raising the pivot
  translates the view up, so the tank now sits lower in frame than before. Also unverified: the
  arm's collision behaviour — every reading was uncollided at the full 13.0 spring length.
- also noted: ground facet normals read `n.y` of **−1.0**, i.e. downward, on ground whose outward
  direction is up. Pre-existing, from the marching-cubes winding in `chunk.gd:271`, and untouched
  by this session; `abs()` makes the relief fade sign-agnostic. It does mean lit shading uses a
  downward normal — worth a look, out of scope here.

Two reports from playing S1. Both land in files S2 does not touch, so they run first.

**1. The camera sits too low — and S1 is why.** Before S1 the arm pitch at rest was
`-8 * 0.6 - 10 = -14.8°`; it is now `8 * 0.6 - 5 = -0.2°`. The pivot is 2.7 above the tank
origin (`Turret` y 1.3 + `CameraArm` y 1.4) on a 13-unit arm, so the resting camera fell from
about **6.0 to 2.75** units above the tank. The old formula's `-10` bias was doing double duty
as a height offset and the fix removed it without replacing it.

**Do not fix this by re-biasing the pitch.** Tangling height into the pitch term is what made
the original line hard to read, and it is why the inversion hid there for so long. Separate
them: **height is the pivot's y** (or an explicit offset), **pitch is what follows the gun**.
Name both constants — `CAMERA_PITCH_FOLLOW` (0.6) and `CAMERA_PITCH_BIAS` (−5.0) — so the next
person changing one does not silently change the other.

Measure `camera.global_position.y - tank.global_position.y` at `barrel_pitch` 8 (rest), −12 and
+42, and report all three. "A little higher" is the ask, so land it and let the user judge; the
gate is that it moved up and is measured, not a specific number.

**This session also closes S1's open item.** S1 left unverified that at `barrel_pitch` 42 the
uncollided `Camera3D` sits 1.79 m *below* the hull origin. Raising the pivot should fix it —
re-measure it and say whether it did.

**2. Contour lines flicker at the lowest point on the map.** Reported as "transparent
flickering". Two candidate causes, both consistent with it happening at the valley floor.
**Measure which one before fixing** — they have different fixes and the wrong one passes every
test.

- **(a) Flat ground collapses `fwidth` to zero.** The valley floor is near-horizontal, so world
  Y barely changes across it and `f = y / interval` barely changes per pixel. `fwidth(f) → 0`
  does two things: `smoothstep(width + fw, width - fw, d)` loses all antialiasing and becomes a
  hard step, and the existing fade term `(1.0 - smoothstep(0.35, 0.5, fw))` is built for the
  *opposite* end — it fades lines that bunch too tight on steep faces and does nothing here. A
  flat area whose height sits near a contour multiple then flips wholesale between lit and unlit
  as sub-voxel height variation crosses the threshold. That is what flickering over an *area*
  looks like.
- **(b) Emission-only lines on near-black albedo, through bloom.** Contours went into `EMISSION`
  and not `ALBEDO`. The valley floor is the darkest part of the frame (`base_color` is
  0.02/0.03/0.06 and it is in shadow) and `glow_hdr_threshold` is 0.85, so a line sitting at the
  bloom threshold shimmers as the camera moves.

**The check that separates them:** (a) correlates with the surface **normal**, (b) with screen
**brightness**. Shoot the valley floor from two distances — (a) changes with the grazing angle,
(b) does not.

If it is (a), which is the likelier, the fix is what real contour maps do: **there is no contour
line on flat ground.** Fade the contour by how fast world Y actually changes across the surface
rather than antialiasing a band with no gradient to antialias against. `1.0 - abs(n.y)` is the
cheap version and `v_world_normal` is already there.

**Do not fix it by raising `contour_width` or lowering `contour_strength`.** Both make the
artifact less visible without removing it, and both cost the contours everywhere else.

**On the gate, and why it does not measure the flicker.** Flicker is temporal and
`--harness-shot` renders one frame, so there is nothing to measure it with — do not build
frame-differencing scaffolding to try. Measure the **mechanism** instead: pick one
near-horizontal region and one sloped region on the same shot, and show the contour contribution
collapsing on the flat one while surviving on the slope. The user confirms the symptom by eye.
Use S1's control (`.claude/images/s1-review-after.png`, pose `0,120,120:0,0,0`) plus a fresh
low-angle shot of the valley floor, which S1 never took.

**Corrected 2026-08-30, after the fact.** This line originally named `s1-contours-before.png`,
which is S1's **pre-contour** frame: it differs from the post-S1 build by *two* changes, not one
(the contours, and the grid dial-back `emission_strength` 2.4 → 1.6 and `line_width` 0.045 →
0.035 in the same commit), so a pure contour fade measures against it as *adding* +14.9 luma,
which a fade cannot do. `s1-review-after.png` is the true post-S1 state — verified by measuring
it against `s1-contours-after.png` and getting delta 0 on every field, not by mtime. See
`.claude/learnings/2026-08-30-control-shot-is-only-a-control-for-its-commit.md`.

---

## S2 — Strip the Wild Metal Country combat scaffolding
- status: done
- depends: S1b
- landed: 2026-08-30, Reviewer-verified. Deletion only, and it measures as deletion only. The
  baseline was taken by the orchestrator at HEAD **before the first spawn**, because the first
  edit destroys it. **Unmoved, all bit-identical:** `chunks_total` 192, `terrain_triangles`
  95058, `craters_carved` 0, `explosions_spawned` 0, `tank_spawn_height` **−8.57074508368969**
  (the sharp one — derived from the terrain at the origin, so any movement would mean the level
  build changed), `trip_active` false, `spawn_failures` 0, both world extents 192.0,
  `vertical_extent()` 49.06. **Spawn counters to zero against an empty manifest:**
  `entities_spawned` 17 → **0**, `enemies_alive` 5 → **0**, `enemies_total` 5 → **0**,
  `spawn_manifest.size()` 2 → **0**, and both clearances to the documented `inf` sentinel
  (`min_spawn_clearance` 9.0377197265625, `min_ground_clearance` 0.19999915711526). Corroborated
  off a quantity the change does not compute: `$Spawn.get_child_count()` = 0.
  **The empty manifest is the valley's, not a fallback's** — `main.gd:181` builds a default
  `LevelDef` whose manifest is *also* empty, so `size() == 0` alone cannot tell them apart.
  Settled on the reference: `level.resource_path` = `res://levels/valley.tres`, plus
  `field` / `surface_material` / `environment` all resolving to real paths where a
  default-constructed `LevelDef` has `null` for each, plus `errors=0` proving the
  `push_error` on that fallback branch never fired. Note `spawn_clearance` 4.0, `trip_fade` 1.2,
  `spawn_seed` 20260826 and `player_keepout` 26.0 are identical in the `.tres` and in the script
  defaults, so **none of them could have distinguished the two paths.**
  `check_resources PASS {"checked":12 → 9,"failed":[]}` — exactly three resources left the
  project and nothing else did. No orphan `.uid` (disk scan; the `.uid` was deleted as a pair).
  `load_steps` 13 → 7. `5_rule` and `6_group` are kept, unreferenced: `Array[SpawnGroup]([])`
  needs `6_group` to resolve the array's element type, and S4 needs both declarations back.
  `CollisionLayers` — `PICKUPS`/`TRIGGERS` gone, `PLAYER_SHELLS` (1<<2) and `ENEMY_SHELLS`
  (1<<4) untouched; live tank re-measured at layer **2** / mask **9**, terrain chunk **1** / **0**,
  and `(layer | mask) & 20 = 0` across live bodies proves the reserved bits are carried by
  nothing. Tests 1–6 pass; fps min **118.0** avg 119.7, load **5.104 s** headless / **4.34 s**
  windowed, zero errors and zero warnings. Test 6 `RENDER: PASS`, and against the control the
  removal is *localized*: whole frame, ground box and sky box all `delta.luma_mean 0.0`, with 6
  of 32 swept columns losing the props' emissive teal (c10 `delta.hue_frac.cyan` −0.0024 /
  `delta.distinct_colours` −8; c25 −0.0023 / −10) and the other 26 pixel-identical.
- also noted: the `.godot/` cache was stale after the deletion — it still registered `EnemyBody`
  and still recorded `valley.tres` depending on both deleted scenes — **and tests 1 and 2 passed
  green over it**. `CLAUDE.md § Traps` describes the move/rename symptom (`Failed loading
  resource:`), which never appeared here. Deleted and rebuilt; filed to the learnings inbox.
- unverified: nothing that bears on the gate. The two reserved collision constants could not be
  read directly — `--harness-eval` cannot reach a `const` on a `class_name` script with no live
  instance — so their bit positions are source-verified and corroborated by absence across live
  bodies, not harness-verified. Filed to the inbox.

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
- status: done
- depends: S2
- landed: 2026-08-30, Reviewer-verified. The voxel renderer is replaced by a geometry clipmap
  and the glen is mapped 1:1. **World 2022 × 2010** (`world_extent_x()` **1011.0**,
  `world_extent_z()` **1005.0**), from `world_size` 384 → **(2022, 2010)** and `height_scale`
  0.08 → **0.42125** (= 0.08 × 2022/384). **Load 2.26 s headless / 2.19 s windowed**, down from
  5.104 / 4.34 — the world grew 27× in area and got *faster*. Test 4 **fps min 119.0 avg 119.8
  max 121.0** over 10 samples, against a gate floor of 60 and a baseline min of 118.0.
  `chunks_total` 192 → **6**, `terrain_triangles` 95058 → **38912**.
  **The gate's central clause was settled on both halves, separately.** The *collidable* half:
  `max_collision_disagreement` against `field.ground.surface_height()` = **0.00479820846981**
  over **49** rays on the Reviewer's own point set (Doer: 0.000149/25 rays, 0.00380/36), gate
  20 rays under 0.5; the function returns `INF` on a miss, so a finite value also proves
  collision exists at all 49 points. The *visible* half was **not** taken on
  `max_render_disagreement` **0.0699**, which is a CPU mirror of the shader's arithmetic and not
  evidence for the GLSL — the Doer said so itself. It was closed on **pixels, at two camera
  heights**: the terrain silhouette's half-signal crossing measured **y ≈ 0.490** against
  **0.4897** predicted from `field.ground.surface_height()` alone (edge-extended plateau
  −40.115, camera −56, vFOV 75), and on a control camera 456 units higher, **0.631** measured
  against **0.640** predicted. Two features, two poses, both landing where the CPU field says.
  **Horizon region check** (`.claude/images/s3-horizon.png`, pose `0,-56,0:0,-56,2000`) against
  a *constructed* control (`s3-sky-control.png`, camera y 400 — above `_height_max` 258.33, so
  no region above frame-y 0.5 can contain terrain **by construction**): the control region
  measured **Δ0.0 on both channels**, pixel-identical, while the horizon band moved
  **+103.9 luma and −0.641 purple**. Ground at the horizon, not sky, against a measured zero.
  **Requirement 3 held.** `max_world_gradient` 1.89054 → **1.89957** (+0.48 %, the z axis at
  2010 against x at 2022). Corroborated on quantities derived differently:
  `vertical_extent()` 49.06 → **258.3316** and `surface_height_range()` (−20.538, 47.306,
  16.793) → **(−108.1468, 249.0957, 88.42439)**, every component **×5.2656 = 0.42125/0.08
  exactly**, so gradients are invariant by construction rather than by luck.
  **Requirement 4 re-measured, and the answer was to keep the constants.** Relief quantiles over
  1600 points: p25 **0.00364**, p50 **0.02758**, p75 0.05321, max 0.44616 — corroborated off a
  path sharing no code, `TerrainAnalysis.slope_degrees` over 400 candidates giving p25 4.912°
  and p50 13.488°, whose `1 − cos` are 0.00367 and 0.02757 (three significant figures on both).
  `CONTOUR_RELIEF_MIN` 0.003 still sits inside the flattest quarter and `CONTOUR_RELIEF_FULL`
  0.012 still sits in the gap to the median — unchanged **because** `height_scale` moved with
  `world_size`. Contour density 357.2/20.0 = 17.9 minor lines against 67.84/4.0 = 17.0 before.
  **Shape.** New base class `terrain/terrain_surface.gd`; both renderers extend it and the four
  `Terrain`-typed call sites (`spawner.gd`, `TerrainAnalysis.gd`, `ui.gd`) name it instead. The
  four counters became **methods** (`triangle_count()`, `chunk_count()`, `crater_count()`,
  `is_destructible()`) because GDScript cannot override an inherited var with a property.
  `build()` samples the field once into an `R32F` texture of **world heights**; the shader reads
  it with `texelFetch` + bilinear and the collider is built from the **same**
  `PackedFloat32Array` — verified structural, not coincidental: live shader uniforms
  `map_dim (1013,1007)`, `map_step (2,2)`, `map_origin (−1012,−1006)` match
  `collision_grid_size()` **(1013, 1007)** exactly. Ring seams use four pre-built hole variants
  per level: `ring_seam_mismatch()` = **0.0** at seven follow positions driving `_active_variant`
  through all four variants, with `triangle_count()` 38912 throughout.
  **Collision re-measured off the live bodies:** terrain `collision_layer` **1** / `mask` **0** /
  `scale` **(2, 1, 2)** (uniform in x/z, 1.0 in y so heights are not stretched); tank **2**/**9**
  unmoved; `get_child_count()` = **7** = one `StaticBody3D` + six levels, i.e. **exactly one
  collider** — the stacked-body trap's shape, absent.
  Marching cubes `git mv`'d to `terrain/voxel/` with its `.uid` pairs; `.godot/` verified clean
  by grep (`global_script_class_cache.cfg` carries the new paths and no stale one survives),
  which matters because S2 recorded that a stale cache passes tests 1 and 2 green.
  `levels/valley.tres` changed by exactly one `ext_resource` path (`neon_terrain.tres` →
  `heightmap_terrain.tres`), `load_steps` and every hand-numbered id untouched.
  Retunes: `contour_interval` 4.0 → **20.0**, `fog_density` 0.0022 → **0.0004**,
  `directional_shadow_max_distance` 320 → **1200**; camera `far` already 3000, untouched.
  `custom_aabb` P(−64, −161.07, −64) S(128, 469.40, 128) is load-bearing — the mesh AABB is a
  zero-thickness slab (S 128, **0.00001**, 128) because height only exists after the vertex
  shader, so without the override Godot culls rings that are plainly on screen.
  Tests 1–6 pass; `check_resources PASS {"checked":9 → 11,"failed":[]}` — the new shader and
  material and nothing else; zero errors and zero warnings.
- unverified: **driving it.** "Drivable end to end" rests on the 49 raycasts plus max pool slope
  **49.094°** against the tank's `floor_max_angle` 0.9 rad = **51.57°** — nobody drove 2022
  units, and Jolt's scaled heightfield was verified by static raycasts only, never under a
  moving body. **LOD popping at ring boundaries** is temporal and needs hands; the roadmap said
  measure before spending on geomorphing, and it could not be measured here.
  **Composition and colour** of `s3-horizon.png` and `s3-doer-look.png` are for the eye — the
  render checks answer "does it render", not "does it look good".
  `surface_clearance()` **has no successor**: it measured the gap to a meshed box's roof and
  floor, and a clipmap has no box, so the baseline's 24.694 is not comparable to anything.
  The voxel `Terrain` build path is now **exercised by nothing** — it compiles and its resources
  load, but no test instantiates it, so the edits to its `extends` are compile-verified only.
- also noted: **the collider footprint is smaller than the drawn extent.** The
  `HeightMapShape3D` spans x ∈ [−1012, +1012] and z ∈ [−1006, +1006]; the clipmap draws to
  ±2048 from the tank. So there are roughly 1000 units of drawn-but-not-collidable ground on
  every side, and driving past the footprint edge is a fall to `death_height` −181.073
  (`world_floor()` −161.073). This is consistent with the edge-extended flat horizon this
  session asked for on purpose — "the 'still in the world' illusion, for free" — but it is the
  one place the gate's headline sentence does not hold, and it was in neither agent's plan.
  Also: `terrain/materials/neon_terrain.tres` still carries `contour_interval = 4.0` while the
  new material moved to 20.0. Harmless while nothing instances the voxel renderer, but the new
  shader's header states the two fragment halves must be retuned together and this pass retuned
  one — it matters whenever destruction returns.

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

   **And re-derive S1b's relief fade in the same pass.** `CONTOUR_RELIEF_MIN` 0.003 /
   `CONTOUR_RELIEF_FULL` 0.012 in the shader are calibrated against **marching-cubes** facet
   normals, which are flat per triangle — that is why the valley floor measured `1 - |n.y|` of
   exactly 0.0000 and why the artifact existed at all. A clipmap displacing a grid in the vertex
   shader produces *continuous* normals, so both the artifact and the two populations those
   consts sit between change shape. Re-measure `1 - |n.y|` on flat and sloped ground under the
   new renderer before trusting either number.

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

**What S2 left you** (2026-08-30). `levels/valley.tres` now has `spawn_manifest =
Array[SpawnGroup]([])`, so this session **populates an empty manifest** rather than adding a
third group beside guardians and props. The `5_rule` (`PlacementRule`) and `6_group`
(`SpawnGroup`) `ext_resource` declarations were deliberately kept in that file, unreferenced, so
authoring a group here needs no new declaration — `6_group` is in fact load-bearing already, as
the empty typed array will not resolve without it. `Damageable`, `DamageProfile`, `SkinSlot`,
`Spawner` and `TerrainAnalysis` all survive untouched. What does **not** survive is any example
to copy: `guardian_placeholder.tscn` and `prop_placeholder.tscn` are gone, so a tower scene is
authored from nothing. The deleted guardian was `StaticBody3D` + `CollisionShape3D` + a `Skin`
node holding meshes + a `Damageable` carrying a `DamageProfile`, and its layer/mask were set in
script rather than in the `.tscn` — read `entities/CollisionLayers.gd`'s header for why before
setting them anywhere else. The old guardian profile, as a starting point rather than an
authority: `max_health` 240.0, `armour` 8.0, `resistance` (1, 0.75, 1.25),
`min_damage_fraction` 0.1. Its placement rule, which S3 invalidates and this session must
re-derive: ridgelines, slope 0–25°, elevation percentile 0.65–1.0, openness 0.7–1.0,
`ground_clearance` 0.4, `separation` 28.0.

The old thresholds are also still written down in `docs/foundation-plan.md` §4, kept there on
purpose as the derivation to start from — not as numbers that still hold.

This is the first change that makes a shell *do* something, so it is bigger than it looks.
`tank/shell.gd` masks `CollisionLayers.TERRAIN` only and applies no damage at all — it emits
`shell_exploded` and frees itself.

**1. Shells carry damage.** Add `@export var damage: float = 20.0` and
`@export var damage_type: int = DamageProfile.Type.KINETIC`. In `_detonate()`, before emitting,
look for a `Damageable` on the collider (`hit["collider"]`) and call `apply_damage()`. Widen
`hit_mask` to `TERRAIN | STRUCTURES`.

Add `CollisionLayers.STRUCTURES := 1 << 5` for towers. **Do not rename `ENEMIES`.**

*Revised 2026-08-30.* This line used to say rename `ENEMIES` to `STRUCTURES`, on the grounds
that nothing fights back any more. **S4c makes that false** — red tanks arrive and they are
exactly what `ENEMIES` was named for. So `ENEMIES` (`1 << 3`) stays where it is and keeps its
name, and towers get their own bit. Two bits rather than one is not bookkeeping: S4c's aggro
query has to find the player without finding a tower, and a shell has to damage both, so the
one place they are the same is the shell's `hit_mask` and everywhere else they differ.
`1 << 5` is free — S2 deleted `PICKUPS` and `TRIGGERS` from that range and `PLAYER_SHELLS`
(`1 << 2`) and `ENEMY_SHELLS` (`1 << 4`) are reserved and must stay empty.

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

**What S3 left you** (2026-08-30). Some of that measuring is already done, on the post-S3
field, and is in S3's landed note above: `TerrainAnalysis.slope_degrees` over 400 candidates
gives **p25 4.912°** and **p50 13.488°**, with a **max pool slope of 49.094°**; relief
`1 − |n.y|` over 1600 points gives p25 0.00364, p50 0.02758, p75 0.05321, max 0.44616. Take
these as the starting distribution rather than re-buying the launches, but re-derive anything
the rule actually gates on — the old guardian rule's *elevation percentile* and *openness*
bands were never re-measured at this scale, and `sightline_range` is still 60.0 against a world
that is now 2022 units across, so "openness" no longer means what it meant at 384.
Placement stays inside collidable ground for free: `TerrainAnalysis` bounds itself with
`world_extent_x()` / `world_extent_z()`, which return **1011.0 / 1005.0** — the collider's
footprint, not the clipmap's ±2048 draw distance. Do not widen it to the drawn extent; S3's
"also noted" says why.

**5. Harness surface.** `towers_alive` and `towers_total` on `main.gd`, as computed getters off
the live nodes, never mirrored per frame. `main.gd` already has `enemies_alive` /
`enemies_total` doing exactly this against `Spawner.live_damageable_count()` — rename rather
than add.

**The gate, precisely.** Four `apply_damage(20.0)` calls leave `is_alive` true and
`towers_alive` unmoved; the fifth flips both. Both halves matter — a tower that dies in three
hits passes a test that only checks it dies.

---

## S4b — Shells that hurt, and a tank that can die
- status: todo
- depends: S4
- gate: on the live nodes, a direct hit, a hit at the blast edge and a hit just outside it are
  three distinguishable numbers off `Damageable.health`, the direct hit at least 4× the edge
  hit and the outside hit **exactly zero**; the player survives two direct hits and dies on the
  third (`alive` reads true, true, false); a kill heals the player by the authored amount and
  never above `max_health`; the HUD bar's own width var tracks `health_fraction()` at three
  different healths.

**What is wanted:** shells that do damage where they land and less damage nearby, a player that
can be killed, and a bar for both. **No AI here** — S4c brings the things that shoot back. This
is the substrate, and it is deliberately proved against S4's towers, which do not move.

**Why this before the enemies, and not merged with them.** Every clause in the gate is
measurable on a static target through `--harness-eval`. Wiring the same machinery to something
that patrols means debugging damage and AI at once, and from outside they fail identically: the
thing did not die. Split here and each half has a gate that can actually fail for one reason.

**1. Splash damage.** `tank/shell.gd` already carries `@export var blast_radius: float = 8.0`
and already emits `GameEvents.shell_exploded(centre, blast_radius)`. The radius exists, the bus
already carries it, and the terrain already listens — so this is one more listener, not a new
concept. Damage falls off from full at the centre to a floor at `blast_radius` and **zero
beyond it**, which is the clause that says the falloff is a falloff and not a constant.

Direct damage is S4's `Shell.damage`. Splash is a separate authored number, because "a near
miss does 40 % of a hit" is a feel dial and folding it into the falloff curve hides it.

**Do not apply both to the same target.** A shell that hits a tower dead-on and then also
catches it in its own blast does damage twice, reads as "direct hits do double", and every test
in the sequence passes. Whatever the shape, name the exclusion explicitly in the code.

**2. The player can be damaged.** `tank/tank.gd` has `alive`, `spawn_position`, `death_height`
and `respawn()` — a tank that can already *die* by falling, with no health at all. Give it a
`Damageable` with `entities/profiles/player_tank.tres`, and route death into the reset path
that `death_height` already uses rather than inventing a second one.

**Three hits means `max_health = 3 × Shell.damage` derived in one place**, the way S4 derives
the tower's five. Author `armour = 0.0` and `resistance = (1, 1, 1)` on the player profile so
the arithmetic is exact and the gate is a clean true/true/false — otherwise `min_damage_fraction`
and armour make the third hit a coin flip.

**The dial, named because it is a dial.** "Sustain 3 direct hits" is read here as *dies on the
third* — a 3:1 toughness ratio against an enemy that dies to one. If it should mean *survives
three and dies on the fourth*, that is `max_health = 4 × damage` and nothing else changes.

**3. Health bars.** Two of them, and they are not the same widget.
- **Player:** screen-space in `UI/ui.gd`, beside the existing reload bar. That file already
  owns `reload_bar` / `reload_frame` and a `_frame_width` — follow that pattern, do not
  introduce a second one.
- **Enemy/tower:** world-space, above the target, and this one is S4c's real consumer. Build it
  here as a reusable node driven by `Damageable.health_fraction()`, which is documented in
  `entities/damageable.gd:136` as exactly "what a health bar reads".

**Do not prove the bar by reading the bar's pixels or its material back.** That is re-reading
what the change just wrote (`CLAUDE.md § Traps`). Read `Damageable.health` and the bar node's
own width/scale var, which are derived differently, and confirm the visual separately with a
region check.

**4. Healing.** `Damageable` already anticipates this: `damage_absorbed` is documented as
"independent of `health` for anything that heals or repairs later". Add `heal(amount)` there,
clamped at `max_health`, and have the level — not the tank, and not the enemy — decide that a
kill heals the player. A tank that knows killing heals it is the coupling `main.gd`'s header
exists to prevent; the level is the thing that knows both parties.

Exercise it here against a tower kill. S4c changes nothing about this path.

**Watch for:** `shell.gd:29-40` carries a long comment explaining that `hit_mask` is terrain-only
and that adding enemies is **"session E's change"**. Session E was in `docs/foundation-plan.md`
and **S2 deleted it** — the comment now points at a session that does not exist. S4 widens that
mask and this session and S4c widen it again; whoever touches it first should fix the comment
rather than leave three sessions' worth of stale provenance in a load-bearing file.

---

## S4c — The red tanks: patrol, aggro, leash
- status: todo
- depends: S4b
- gate: an unaggroed enemy's distance from its patrol centre stays within its radius across 300
  physics frames; with the player placed in the open inside its sight range the state flips to
  engaging, and with the player at the **same range but behind terrain** it does not — that
  pair is what proves the check is a raycast and not a distance test; at 3× the radius the
  state returns to patrolling and the enemy's position comes back inside the circle; one
  `apply_damage(Shell.damage)` flips `is_alive` false and decrements `enemies_alive`;
  `collision_layer` and `collision_mask` re-measured off every live enemy body.

**What is wanted:** a few enemy tanks — our tank, entirely red — each roaming a circular patch.
Come within their line of sight and they aggro and drive at you. Retreat to 3× the patrol radius
and they give up and go home. One direct hit kills them; three kill you; killing one heals you.

**S2 deleted the last enemy on purpose and this does not resurrect it.** `entities/enemy_body.gd`
and `entities/profiles/guardian_hull.tres` were Wild Metal Country scaffolding for a game that is
not being built, and their placement rules were derived against a 384-unit world. They are in
git history (`a278a88^`) and are worth **reading for the layer/mask wiring only** — not for the
behaviour, and not as a scene to restore.

**This reverses a standing decision, and the reversal is recorded.** `CLAUDE.md § Out of scope`
and this file's Deferred list both named enemy AI as not-being-built. The user asked for it on
2026-08-30; both have been updated. Scoring and win/lose conditions are **still** deferred — an
enemy that kills you and heals you is a mechanic, not an objective, and nothing here should grow
a score.

**1. The enemy entity.** `entities/enemy_tank.gd` + `entities/enemy_tank.tscn`, on
`CollisionLayers.ENEMIES` (`1 << 3`, which S4 was told to leave alone for exactly this).

Reuse the player's chassis rather than authoring a second one — `tank/tank.tscn` is a
`CharacterBody3D` with a turret and a barrel, and the drive constants (`FORWARD_DRIVE` 26.0,
`TURN_RATE` 95.0, `DRAG_COEFF` 0.055) are the feel this project already tuned. **But do not make
the enemy a `Tank`.** `tank/tank.gd` is 372 lines of *input handling*, camera arm, reload timer
and mouse look, none of which an AI wants, and inheriting it means every player-feel change
edits enemy behaviour silently. Lift the drive into something both can use, or give the enemy
its own body and share the constants — S3's `TerrainSurface` is the precedent for that shape.

"Entirely red" is a `SkinSlot` material override, not a new mesh. The evidence it is live is
`resource_path` off the node, plus a region check showing `hue_frac.red` where the enemy is —
`CLAUDE.md` on why a colour value alone is not evidence a reference resolved.

**2. Patrol.** A centre and a radius, authored per enemy. The enemy wanders inside the circle;
the gate samples its distance from the centre over 300 frames and the maximum stays inside.

**3. Aggro, and the half of it that matters.** Line of sight is a **raycast against
`CollisionLayers.TERRAIN`**, from the enemy's eye to the player, plus a range and (optionally) a
facing cone. `entities/TerrainAnalysis.gd:177-193` already does a sightline walk against
`surface_height()` and is worth reading first — but it samples heights on the CPU for placement,
which is a different job from a per-frame physics query, so **read it, do not extend it**.

The gate deliberately tests the negative case at the *same range*, because a distance-only check
passes every positive test. That pair is the session's real content.

**4. Leash.** Beyond 3× the patrol radius the enemy disengages and returns. Hysteresis is not
optional: aggro at range R and leash at 3R are far enough apart that it cannot chatter, and that
gap is the reason the number is 3 and not 1.1.

**5. One hit kills.** `entities/profiles/enemy_tank.tres` with `max_health = Shell.damage`,
`armour = 0.0`. Derived from the shell's number in one place, like S4's tower and S4b's player.

**6. Harness surface.** `enemies_alive` / `enemies_total` on `main.gd` as computed getters off
the live nodes. **These names already existed** — S2 zeroed them against an empty manifest and
they still read off `Spawner.live_damageable_count()`. Reuse rather than add, and note that S4
is separately told to rename them to `towers_*`; whichever session lands second reconciles that,
and the answer is probably both, counted separately.

**The constraint that shapes the whole design, and it is narrower than it looks.**
The harness *can* mutate the live tree — `node.set("prop", v)` and any method call parse and run
setters, proven in `.claude/learnings/2026-08-28-harness-eval-cannot-assign.md` (only the `=`
**syntax** fails, because `Expression` parses one expression). What it cannot do is **let time
pass**: `DevHarness._cmd_eval()` awaits the load once and then runs every expression in a plain
synchronous loop, so no frame ticks between them (`CLAUDE.md § The dev harness`).

So the unbuildable test is "move the world, wait, read the state". **Do not solve that by making
the AI remote-controllable.** `set_target_position()` and an externally-callable
`evaluate_state()` are test hooks wearing production clothes, and they let the gate pass while
the state machine that ships consults none of it.

Two house patterns cover the whole gate between them, and both already exist here.

- **Decisions are pure functions, called directly.** `can_see(from_position) -> bool` and
  `should_leash(from_position) -> bool` take the position as an **argument** rather than
  requiring the world to be moved first, so no waiting is needed and the negative case is two
  calls with two positions. This is `CLAUDE.md`'s existing ruling for input bindings applied
  verbatim — "call the branch bodies directly on the live node instead" — and it is why
  `set_target_position()` is not needed at all.

- **Anything that only exists across frames records its own statistic.** The enemy tracks
  `max_patrol_excursion` in `_physics_process`; a `--quit-after 300` run then reports one
  number. `autoloads/PerfSampler.gd` is the precedent (it samples across frames into a bounded
  array and `--harness-fps` reads it), and so are `Terrain.last_carve_clearance` and
  `Spawner.min_spawn_clearance()`. These are permanent invariants, not scaffolding: a system
  that decides where mass goes over time owes a number about where it went.

  **Corroborate it, because `CLAUDE.md § Traps` applies** — a statistic computed by the code
  under review is not independent evidence for the property it names. Read the enemy's live
  `global_position` against its patrol centre in the same batch; that is derived from the
  transform rather than from the AI's bookkeeping.

**The gap this leaves, stated rather than closed.** Testing `can_see()` proves the predicate,
not that the state machine consults it. Close it the way S2 proved `destructible` was actually
read — by watching a count move: an `aggro_transitions` counter incremented inside the
transition, read after a `--quit-after` run with the player parked in view, is enough and costs
one int.

**Not worth buying: an interleaved wait in the harness.** A `--harness-step=N` between evals is
the general fix and would serve tweens, timers and shell flight too — but `_parse_args()` returns
a Dictionary, so argument order is lost and preserving it means reworking arg parsing in the one
file every test in the sequence depends on. That is a pipeline session, not a line item in this
one. If a later session wants to observe a transition rather than a predicate, revisit it then.

**Not in this session:** enemies that shoot back, pathfinding around obstacles, group behaviour,
or any objective built on top of kills. `ENEMY_SHELLS` (`1 << 4`) stays reserved and empty.

---

## S5 — Hand-authoring affordance
- status: todo
- depends: S4c
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

Named so they are not rediscovered as ideas: scoring, win and lose conditions, multiple levels,
audio, geomorphing across clipmap ring boundaries, terrain that remembers damage across a reset,
GPU marching cubes.

**"Enemy AI of any kind" was on this list and came off it on 2026-08-30**, at the user's
request — see S4c. `CLAUDE.md § Out of scope` was updated in the same pass. **Scoring and
win/lose conditions did not come off**: enemies that patrol, aggro, kill you and heal you when
killed are mechanics, and this is still a mechanics prototype with nothing to win.

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
