# A blast test against a StaticBody proves nothing about a CharacterBody

- date: 2026-08-31
- surfaced-by: reviewer
- run: /begin S4c - the red tanks: patrol, aggro, leash
- target: claude.md

**Evidence.** Under this project's Jolt backend, `DirectSpaceState3D.intersect_shape()` does
not report `CharacterBody3D` at all, while `intersect_ray()` does. Same live shell, same
`hit_mask` 41, `blast_radius` 8.0, one eval batch:
`_damageables_in_blast(enemy_0.global_position)` = **0**, at its hull centre
(`+ Vector3(0,0.75,0)`) = **0**, and at `tower_0.global_position` (a StaticBody3D) = **1**.
The direct-hit path, which is a ray, is unaffected: a shell placed 30 units out with
`velocity (-300,0,0)` and one `_physics_process(0.2)` took enemy_0 from 20.0 hp to 0.0 with
`terrain.crater_count()` still 0, so the ray struck the body and not the ground. The roadmap
had asserted that widening `hit_mask` to ENEMIES "gives the red tanks splash for free"; it
does not, and `tank/shell.gd:114` and `:264` still say it does.

**What it suggests.** A line in Traps beside the existing `intersect_shape()` dedup note: the
query returns *nothing* rather than erroring for a body class it will not report, so a splash
or area test that passes against towers is not evidence for tanks, players, or anything else
on a CharacterBody3D. Assert the query returns the new body BEFORE reading damage off it -
the same shape as the dedup rule already in force. Independently: any session planning
area-of-effect damage on characters needs a shape-cast replacement or an overlap test that
does not go through `intersect_shape`.
