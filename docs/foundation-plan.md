# Foundation plan — a Wild Metal Country early level

Agreed 2026-08-25. **This spans several sessions**, and the per-session budgets never reset, so
each session starts cold and reads this file first. `CLAUDE.md` is the operational contract;
this is the design contract. Where they disagree, `CLAUDE.md` wins.

Update this file when a session lands. A gate that was met should say so.

---

## What we are building

The recoverable core loop from *Wild Metal Country*: drive a heavy tank across an open hilly
valley, fight autonomous guardian machines, recover power cores, haul them to a collection
gate. Terrain is the cover system — crest a ridge, take fire, back off behind it.

**Not** in scope: multiple levels, campaign progression, scoring, enemy variety beyond two
archetypes. This is one level, built on foundations that make the second one cheap.

## Decisions locked

| Question | Decision |
|---|---|
| Valley shape | **DEM heightmap base + fBm detail + smart scatter.** Real elevation data supplies the large-scale shape; noise supplies everything below ~30 m. |
| Heightmap sourcing | **NASADEM 30 m via OpenTopography**, chosen 2026-08-25 — the only public-domain route that covers Scotland. Crop a real glen. Full provenance, crop plan and licence structure in `assets/incoming/terrain-heightmap.source.json`. Copernicus excluded (requires attribution). |
| Core retrieval | **Drive-over pickup**, deliver by entering the gate zone. The objective API is written so a tractor-beam tow replaces the pickup without touching the tracker, the HUD or the LevelDef. |
| Modularity | **Both axes.** Content is data (`.tres`); tank stats sit behind a modifier stack so in-game upgrades drop in later as data. |
| Asset sourcing priority | **Player tank / vehicle hulls first.** Guardians and structures deferred — nothing integrates before session H. |

### Why DEM-plus-noise, and the scale arithmetic

The heightmap is the **silhouette**; fBm is the **surface**. The heightmap carries nothing below
about 30 m and is not expected to.

> **Corrected 2026-08-25 — the first version of this section reasoned wrongly, and the wrong
> version is the intuitive one.** It said: the world is 192 m across, 30 m/px gives 6×6 pixels,
> therefore 30 m data is useless. That silently assumes the real world maps **1:1** onto the game
> world. It does not have to. **Crop a larger region and compress it.** A 2 km crop at 30 m/px is
> ~67×67 px squashed ~10× into the 192 m footprint — a real glen's floor, flanking ridges and
> spurs, at a resolution entirely sufficient for a shape that carries nothing below 30 m.
>
> Anyone changing the world size should re-derive the ratio from the crop, not assume the source
> resolution decides it.

**The vertical scale does not survive that compression.** Real relief in a Scottish glen is
several hundred metres; the current terrain has ~17 m of relief (`SDFHills` amplitude 22 —
measured, see that file's header). `SDFHeightmap.height_scale` will therefore be a small fraction
of real, order 0.02–0.05. **Tune it against `Terrain.surface_height_range()`**, which returns a
measured min/max/mean over a sampled grid, rather than guessing — and note why that function
exists: Perlin noise is exactly zero at every integer lattice point, so three sampled points
report flat ground on terrain that is not.

### The conversion step

**Godot reads PNG, EXR and HDR. It does not read GeoTIFF, IMG, Arc ASCII or HGT**, which is
everything the DEM sources offer. One conversion sits between the download and the engine:

```bash
gdal_translate -ot UInt16 -scale -of PNG <input>.tif assets/incoming/valley-heightmap.png
```

It must end up **16-bit**. No source page stated its input bit depth, so verify the output rather
than assuming the flag had something to preserve.

### Effects are code, not assets

Explosions, muzzle flash, core glow, shield shimmer, tractor beam. `effects/explosion_director.gd`
already states why, and a downloaded VFX asset would be strictly worse here. **Do not send the
modeller at effects.** The power core is likewise a sphere plus a shader, not a mesh.

---

## Architecture

Five layers, bottom to top. Each session builds one and the gate is that the layer below is
untouched.

### 1. Field stack (sessions B and C)

`SDFHills.sample()` is `p.y - surface_height(x, z)`. A heightmap field is the same shape, so:

- ✅ **`SDFComposite extends SDF`** (B) — layers a list of fields through the existing `SDFOps`
  combinators. `heightmap ⊕ fBm detail ⊕ authored primitives`. Reports `max(layer.lipschitz)`,
  doubled if any seam is a smoothed op.
- ✅ **`TerrainField.ground` widens from `SDFHills` to `SDF`.** (B) Craters keep working
  *identically* — carving already sits in a layer above the ground field, and that is the
  property that makes this whole approach safe. **Measured, not assumed:** a carve flips
  `field.sample()` from -4.0 to +4.5 at a point below the surface while `ground.sample()` holds
  at -4.0.
- ✅ **An optional height-field interface on `SDF`** (B) — `surface_height(x, z)` and
  `vertical_extent()`, both `push_error` by default. `Terrain.surface_height()` and the shader's
  `height_range` ramp both reached through `ground` for `SDFHills`-only members, so widening the
  type needed somewhere for those to land. They stay **derived from the live field**; nothing is
  copied onto `LevelDef`, which is what stops the ramp going stale when amplitude is retuned.
- **`SDFHeightmap extends SDF`** (**C**, needs `valley-heightmap.png` on disk) — image, world
  size, height scale, vertical offset, bilinear sample. Identical interface to `SDFHills`. It
  arrives as one more layer on a mechanism session B already verified.

Two import gotchas, both silent:

- An 8-bit PNG gives 256 height steps and **bands visibly** on smooth slopes. Use 16-bit PNG or
  `.exr`.
- The heightmap must import as **`Image` data, not a VRAM-compressed `Texture2D`** — a
  compressed texture cannot be read back cleanly at runtime.

### 2. Level as data (session B) ✅

`main.gd` → **`LevelRunner`** plus a **`LevelDef`** Resource. Same doctrine `main.gd` already
states — *anything that has to know about two systems is a level concern* — but a new level
becomes a `.tres` instead of a script. Shipped as `levels/valley.tres`.

`LevelDef` holds **field stack, surface material, environment, spawn clearance, trip fade**.
The **spawn manifest lands in D and objectives in G**; they are deliberately absent, so a
session adding them is extending this resource rather than finding it already half-built.

**One trap this created, and it is not obvious.** `Terrain._ready()` still builds a default
`TerrainField` when the node is left unwired, and every value in `world_field.tres` equals its
script's `@export` default — so a `LevelDef` that silently failed to resolve its field would
reproduce *every* number in B's gate table exactly. Equality proves the values match; it does
not prove which path produced them. The evidence that the authored field is live is
`terrain.field.resource_path` and `terrain.field.ground.get_script().resource_path`, read off
the live object. Every session after this one moves more configuration into `.tres` behind a
null-guarded assignment, so this applies to all of them.

### 3. Entity layer (session D)

Components as child nodes configured by exported Resources, **not** inheritance:

Tagged per bullet, because this section lists more than session D built — the session table
at the bottom is the scope boundary and these tags follow it, not the heading above.

- ✅ **`Damageable`** (D) — HP, armour, damage type, all from a `DamageProfile` resource. Emits
  `entity_damaged` / `entity_destroyed` on the bus, and local `damaged` / `destroyed` at the
  entity it hangs off. It never frees anything: what death *looks like* belongs to the entity.
- ✅ **`Spawner`** (D) — generalises `_place_tank()`: snap to surface, clearance-check, reject
  overlaps. Overlap rejection is analytic rather than a physics query, because bodies added in
  the current frame are not in the broadphase until it steps and `intersect_shape()` against
  one returns nothing — an overlap check that passes everything and looks like it works.
- ✅ **`CollisionLayers`** (D) — named bits, and the ruling that a body's layers are assigned in
  its script and never in its `.tscn`. See that file's header for why.
- **`WeaponMount` + `WeaponDef`** (**E**) — shell scene, muzzle velocity, reload, damage, blast
  radius. The player tank and a guardian turret differ by *data*.
- **`AIBrain`** (**F**) — sensor + state machine, one per guardian archetype.

### 4. Terrain analysis + scatter (session D)

A **`TerrainAnalysis`** pass computing per-candidate-point **slope**, **elevation percentile**
and **openness / sightline**. Placement rules then become data:

| Entity | Rule |
|---|---|
| Guardians | Ridgelines with long sightlines |
| Power cores | Hollows and dead ground |
| Gate | Flat ground near a map edge |
| Props | Mid-slopes, off the drivable routes |

This is the piece that makes a real DEM worth having: it finds the valley's natural strongpoints
instead of us placing them by hand.

✅ **Landed in D**, as `TerrainAnalysis` plus a `PlacementRule` resource per rule. Guardians and
props are authored in `levels/valley.tres`; cores and the gate are session G and are absent
rather than stubbed.

**Every slope, openness and elevation threshold in that manifest sits between two measured
numbers**, which is only possible because `TerrainAnalysis.metrics_summary()` writes the
quantiles of those three to the session log on every load. Measured over 400 candidates on the
session-B hills:

| metric | min | p25 | p50 | p75 | max |
|---|---|---|---|---|---|
| slope° | 1.64 | 11.94 | 17.83 | 29.95 | 48.51 |
| openness | 0.125 | 0.484 | 0.688 | 0.875 | 1.0 |
| height | −9.53 | −3.26 | −1.51 | 1.45 | 7.35 |

The first draft of the guardian rule used `min_openness = 0.45`, below p25, and **rejected zero
candidates** — a "long sightlines" criterion that did nothing. It is now 0.70, between p50 and
p75. Props moved to the measured interquartile slope band (12–30°), which is what "mid-slopes"
means here rather than a guess. **Session C replaces the hills with a real DEM and every bound
in the table above needs re-deriving from the new quantiles then** — they are relative to this
valley, not absolute.

**The fourth metric, `edge_fraction`, is deliberately not in that table and is not authored in
`valley.tres`.** It is a property of the world box rather than of the terrain, so no quantiles
are published for it and it has a closed-form floor instead: candidates are held `edge_margin`
inside the world, so the smallest achievable value is `edge_margin / world_extent`, today
6 / 96 = **0.0625**. The first draft authored `0.06` and `0.03` — both below the floor, so both
were inert, the same defect as the openness bound above shipped one rule later. Both rules now
leave the edge bounds at their permissive defaults, because `edge_margin` already excludes the
map edge. Session G's gate rule (*flat ground near a map edge*) is what `max_edge_fraction`
exists for; whoever authors it should derive the floor first.

### 5. Stats and upgrades (session E)

`TankStats` Resource of base values; a runtime `StatBlock` applies an ordered list of
`StatModifier` resources. Drive and gunnery read through the block, never constants.

> **Consequence, do not lose this.** `tank.gd` declares `FORWARD_DRIVE` etc. as `const`
> *specifically* so the harness can read them via `get_script_constant_map()`. Moving them into
> a Resource breaks that read path. The harness then reads `scene.tank.stats.forward_drive`
> instead, which works — `--harness-eval` walks the scene tree — but the tests that use the
> constant map must be updated in the same change or they will silently test nothing.

---

## Collision layers

**Load-bearing, and easy to get silently wrong.** Godot's editor numbers layers from 1; code
shifts from bit 0. Re-measure `collision_layer` and `collision_mask` on every new body rather
than reading intent off the diff.

| Bit | Editor layer | Contents | Status |
|---|---|---|---|
| 0 | 1 | Terrain | exists |
| 1 | 2 | Player tank | exists |
| 2 | 3 | Player shells | **reserved** — shells are raycasts with no body |
| 3 | 4 | Enemies | new |
| 4 | 5 | Enemy shells | **reserved**, same reason |
| 5 | 6 | Pickups (power cores) | new |
| 6 | 7 | Trigger zones (gate) | new |

Masks:

| Body | Layer | Masks |
|---|---|---|
| Terrain chunk | 1 | — (static) |
| Player tank | 2 | 1, 4 — terrain and enemies are solid |
| Player shell (raycast) | — | 1 today; 1, 4 in **(E)** |
| Enemy body | 4 | 1, 2 |
| Enemy shell (raycast) | — | 1, 2 |
| Core pickup `Area3D` | 6 | 2 |
| Gate `Area3D` | 7 | 2 |

Bits 2 and 4 are reserved rather than used: nothing needs to *detect* a shell yet, but point
defence or shell-vs-shell would, and renumbering later is the expensive version.

**A shell that does not mask terrain flies through the world. A shell that masks its own firer
detonates on the barrel.** Both have shipped in this project's parent.

---

## Bus contract

Added to `autoloads/game_events.gd`:

```gdscript
signal entity_damaged(entity: Node3D, amount: float, source: Node3D)
signal entity_destroyed(entity: Node3D, source: Node3D)
signal core_collected(core: Node3D)
signal core_delivered(core: Node3D, delivered_total: int)
signal objective_changed(objective_id: String, state: Dictionary)
signal level_complete(success: bool, stats: Dictionary)
```

**Stays local, does not go on the bus:** turret ↔ its tank, an `AIBrain` ↔ its own body, a
`Damageable` ↔ the entity it hangs off. Routing a parent-child relationship through a global bus
hides that it is local.

## Harness surface

Every new system exposes a **computed-on-read getter** on `LevelRunner`. Never a value mirrored
in `_process()` — see `.claude/learnings/2026-08-19-harness-state-mirrored-per-frame-reads-stale.md`
for the failure that rule was bought with.

Existing: `chunks_total`, `terrain_triangles`, `craters_carved`, `explosions_spawned`,
`tank_spawn_height`, `trip_active`.

Added: `enemies_alive`, `enemies_total`, `cores_remaining`, `cores_delivered`, `tank_health`,
`tank_health_max`, `objective_state`, `level_state`, **`spawn_failures`**.

`spawn_failures` matters more than it looks. The scatter pass can fail to place an entity and
carry on, which is exactly the silent-wrong-number failure this pipeline exists to catch.

---

## Sessions

One `/build` per session. Budgets — 12 agent turns, 40 engine launches — are per session and
never reset.

| # | Session | Gate |
|---|---|---|
| A | ✅ **done 2026-08-25.** Spec + sourcing. 0 engine launches, 3 agent turns | This file exists; both candidate lists and provenance sidecars written |
| B | ✅ **done 2026-08-26.** Level data + composite field: `LevelDef`, `LevelRunner`, `SDFComposite`. 16 engine launches, 2 agent turns | **Met.** Single-layer composite over the existing `SDFHills`: `chunks_total` 32, `terrain_triangles` 28414, `surface_height_range()` (-9.792703, 8.059858, 2.712966) — bit-identical before and after. Tests 1–6 pass; fps min 120, load 1.11 s |
| C | Heightmap: `SDFHeightmap`, the glen as a field layer. **Needs `valley-heightmap.png` on disk** | The glen renders and is drivable; load time still under 30 s |
| D | ✅ **done 2026-08-27.** Entity layer + scatter: `Damageable`, `CollisionLayers`, `Spawner`, `TerrainAnalysis`. 32 engine launches, 5 agent turns, two review rounds | **Met, Reviewer-verified.** `spawn_failures` 0, 17 of 17 placed (5 guardians, 12 props). `min_spawn_clearance` +0.35233 m (tightest pair prop_2↔guardian_0, 28.3523 m against a 28 m requirement — computed by hand off the two live transforms, not read off the getter the change itself computes). Surface snap corroborated at non-integer x/z, first *and* last member of a group: guardian_0 0.40000, prop_11 0.19999. Collision measured off live nodes — tank 2/**9**, guardians 8/3, and reserved bits 2 and 4 provably empty (OR of every layer and mask across all nine bodies `& 20` = 0). `chunks_total` 32 and `terrain_triangles` 28414 unmoved. Tests 1–6 pass; fps min 120, load 1.195 s. **Test 6 was shot and column-swept in round 1; in round 2 it was passed by measured identity rather than a fresh shot** — every sampled position bit-identical and the `entities_scattered` log entry byte-identical, so the frame cannot differ |
| E | Combat: `WeaponMount`/`WeaponDef`, damage, tank health, `StatBlock` | Tank can die; shells damage things |
| F | Guardians: turret + hunter, `AIBrain` | Enemies acquire and shoot back |
| G | Objective: cores, gate, tracker, HUD, win/lose | Full loop playable start to finish |
| H | Art: swap skins to downloaded models | Renders; no regression on tests 4 and 5 |

Session B's gate — *nothing visibly changes* — is what makes the riskiest refactor cheap to
verify.

> **B and C were one session until 2026-08-25.** They were split because `SDFHeightmap` cannot be
> meaningfully tested without the converted PNG on disk, and `CLAUDE.md` is explicit that
> `/build` and a manual download **do not chain**. Splitting takes the download off B's critical
> path entirely: a single-layer `SDFComposite` wrapping the current `SDFHills` needs no new asset
> and still proves the layering works, because "identical to today" is a gate that requires
> nothing new to exist. The heightmap then arrives in C as one more layer on a mechanism already
> verified.

Entities carry a **skin slot**: a swappable visual child, so gameplay scenes never reference a
specific mesh and session H is a data change rather than a rework.

---

## Risks

- **Load time.** Test 5 flags above 30 s and meshing scales with `chunk_resolution³`. A bigger
  valley is the most likely thing to blow it. Check this before blaming anything else.
- **Launch budget in C and G.** Visual verification costs one launch per screenshot, and those
  are the two sessions that need the most of it.
- **Perf floor.** Test 4 fails on the *worst* sample, not the average. Several AI agents plus
  particles is exactly what puts a one-second stall in there.
- **Close the Godot editor** before every build session. With the project open it re-saves
  resources from its own in-memory copy and silently overwrites on-disk changes. This has
  already destroyed a completed refactor once.
- **Asset packs.** Drop a `.gdignore` in the staging folder *before* the next engine launch.
  Prefer `.glb` and `preload()` — test 2 does not walk `.gltf`.

## Deferred

Named so they are not rediscovered as ideas: tractor-beam tow, guardian-locked cores, in-game
upgrade fitting UI, second level, audio, enemy variety beyond turret and hunter, terrain that
remembers damage across a reset.
