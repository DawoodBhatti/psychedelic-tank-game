# A before/after equality gate cannot see a fallback whose defaults equal the authored values

- date: 2026-08-26
- surfaced-by: reviewer
- run: /build session B - LevelDef, LevelRunner, SDFComposite
- target: claude.md

**Evidence.** Session B moved `field` off the `Terrain` node in `main.tscn` and into
`levels/valley.tres`, assigned at runtime by `LevelRunner._apply_level()` — but only
`if level.field != null`, with `Terrain._ready()` building `TerrainField.new(); ground =
SDFHills.new()` as a fallback when the node is left unwired. Every value in
`terrain/fields/world_field.tres` is identical to the `@export` default in the script it
instantiates: `amplitude 22.0, frequency 0.011, noise_seed 1337, octaves 4, persistence 0.42,
plateau_strength 0.25, plateau_step 6.0, vertical_offset 0.0`, and `TerrainField.crater_blend
2.0`. So a `valley.tres` that failed to resolve its `field` would have left the throwaway
default live and still produced `chunks_total 32`, `terrain_triangles 28414` and
`surface_height_range() (-9.792703, 8.059858, 2.712966)` — the exact three numbers the Doer
measured before and after and offered as proof the gate held. The gate would have read PASS on
a change that did nothing.

The distinguishing measurement costs one expression in a batch already being run:
`scene.terrain.field.resource_path` = `res://terrain/fields/world_field.tres`, and
`scene.terrain.field.ground.get_script().resource_path` = `res://terrain/sdf/SDFComposite.gd`.
Both measured; both correct here.

**What it suggests.** CLAUDE.md § Traps already warns that "a statistic computed by the change
under review is not independent evidence". This is a different hole and is not written
anywhere: the statistic here is genuinely independent of the change, but the *fallback path*
produces the same value as the feature, so equality proves nothing about which path ran. A
line under "Measure, don't assume": **when a change moves a resource reference, the evidence is
`resource_path` (or the script path) read off the live object, never a number derived from it —
a fallback built from the same defaults is invisible to every derived quantity.** This applies
to every remaining session on the foundation plan, all of which move more configuration into
`.tres` files behind null-guarded assignments.
