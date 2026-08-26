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
| Asset sourcing priority | **Player tank / vehicle hulls first.** Guardians and structures deferred — nothing integrates before session G. |

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

### 1. Field stack (session B)

`SDFHills.sample()` is `p.y - surface_height(x, z)`. A heightmap field is the same shape, so:

- **`SDFHeightmap extends SDF`** — image, world size, height scale, vertical offset, bilinear
  sample. Identical interface to `SDFHills`.
- **`SDFComposite extends SDF`** — layers a list of fields through the existing `SDFOps`
  combinators. `heightmap ⊕ fBm detail ⊕ authored primitives`.
- **`TerrainField.ground` widens from `SDFHills` to `SDF`.** Craters keep working *identically*
  — carving already sits in a layer above the ground field, and that is the property that makes
  this whole approach safe.

Two import gotchas, both silent:

- An 8-bit PNG gives 256 height steps and **bands visibly** on smooth slopes. Use 16-bit PNG or
  `.exr`.
- The heightmap must import as **`Image` data, not a VRAM-compressed `Texture2D`** — a
  compressed texture cannot be read back cleanly at runtime.

### 2. Level as data (session B)

`main.gd` → **`LevelRunner`** plus a **`LevelDef`** Resource holding: field stack, environment,
spawn manifest, objectives. Same doctrine `main.gd` already states — *anything that has to know
about two systems is a level concern* — but a new level becomes a `.tres` instead of a script.

### 3. Entity layer (session C)

Components as child nodes configured by exported Resources, **not** inheritance:

- **`Damageable`** — HP, armour, damage type. Emits on the bus.
- **`WeaponMount` + `WeaponDef`** — shell scene, muzzle velocity, reload, damage, blast radius.
  The player tank and a guardian turret differ by *data*.
- **`AIBrain`** — sensor + state machine, one per guardian archetype.
- **`Spawner`** — generalises `_place_tank()`: snap to surface, clearance-check, reject overlaps.

### 4. Terrain analysis + scatter (session C)

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

### 5. Stats and upgrades (session D)

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
| Player shell (raycast) | — | 1, 4 |
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
| B | Level data + composite field: `LevelDef`, `LevelRunner`, `SDFComposite`. **No asset dependency** | **Plays identically.** A single-layer composite wrapping the existing `SDFHills` reproduces today's terrain exactly |
| C | Heightmap: `SDFHeightmap`, the glen as a field layer. **Needs `valley-heightmap.png` on disk** | The glen renders and is drivable; load time still under 30 s |
| D | Entity layer + scatter: `Damageable`, layers, `Spawner`, `TerrainAnalysis` | Things land sensibly; `spawn_failures == 0` |
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
specific mesh and session G is a data change rather than a rework.

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
