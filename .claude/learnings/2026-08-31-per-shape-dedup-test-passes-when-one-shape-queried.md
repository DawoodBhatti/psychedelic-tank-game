# A per-shape dedup test passes identically when only one shape was in the query

- date: 2026-08-31
- surfaced-by: reviewer
- run: /begin S4b - shells that hurt, and a tank that can die
- target: claude.md

**Evidence.** `Shell._damageables_in_blast()` dedups by `Damageable` instance because
`intersect_shape()` returns one result per *shape*, and a tower carries two
`CollisionShape3D`s. My first check - blast at 4.0 units from a tower, no direct target,
`Damageable.health` 100.0 -> 95.0, one application of `splash_damage_at(4.0)=5.0` - reads
exactly like a dedup pass and tests nothing: tower.tscn's shaft spans y0-20 and its cap
y20-23.2, so an 8-unit sphere at the base overlaps ONE shape. The query returned one hit,
and an un-deduped loop would have printed the same 95.0. Confirming it took a second launch
with `set("blast_radius", 30.0)` and a blast at `tower + (0,20,0)`, which overlaps both
shapes: 100.0 -> 96.0 against 92.0 un-deduped. Note the shipped geometry cannot reach the
path at all - any point overlapping both shapes is >=12 units above the origin, and splash
is measured to the origin against an 8-unit radius, so it returns 0.0 either way.

**What it suggests.** A Traps line: a dedup over a physics-query result is only tested when
the query actually returned more than one result for the target body. The count is the
control - assert the multi-shape overlap (or force it, by widening the query on the live
node) before reading the damage number, or the measurement is a coin flip that always lands
heads.
