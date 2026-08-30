extends Node3D
class_name TerrainSurface

# WHAT EVERY CONSUMER OF "THE GROUND" IN THIS PROJECT IS ALLOWED TO ASSUME.
#
# There are now two renderers for the same world. `terrain/voxel/terrain.gd`
# meshes a density volume with marching cubes and can have holes blown in it;
# `terrain/heightmap/heightmap_terrain.gd` displaces a geometry clipmap in a
# vertex shader and cannot. Neither is a special case of the other and neither
# should extend the other - a clipmap is not a voxel grid with a flag off.
#
# WHY A BASE CLASS AND NOT A LOOSER ANNOTATION. Four call sites name the ground
# by TYPE, statically:
#
#   entities/spawner.gd        `var _terrain:` and `func scatter(terrain: ...)`
#   entities/TerrainAnalysis.gd `var _terrain:` and `func _init(terrain: ...)`
#   UI/ui.gd                   `var terrain:`
#   main.gd                    `@onready var terrain:`
#
# and every one of them is REACHED on a normal load - LevelRunner._scatter_entities()
# calls scatter() unconditionally, scatter() constructs a TerrainAnalysis and
# calls analyse() before it ever looks at the manifest, and ui.gd reads the
# destructible flag every frame. Widening those four annotations to `Node3D`
# would compile and would leave the contract written down nowhere; the only
# record of what the ground owes its consumers would be the crash you get when
# it stops owing it. This file IS that record, and it is the only thing in the
# project that both terrains have to satisfy.
#
# WHAT IS DELIBERATELY NOT HERE. `destructible`, `craters_carved`,
# `triangles_total` and `chunks_total` are plain vars on Terrain, one of them
# with a load-bearing setter (read its docblock before touching it), and the
# clipmap computes its equivalents on read from live nodes. GDScript cannot
# override an inherited var with a property, so hoisting them would have forced
# the clipmap to mirror its numbers into stale copies - exactly what
# main.gd:63 says never to do. They are exposed as METHODS below instead, and
# each terrain answers from whatever it actually keeps.

## The shared density/height field. Both renderers read the ground surface
## through `field.ground`, so a level swaps terrains without re-authoring it.
##
## Left null, each terrain builds itself a default in _ready() rather than
## erroring - that fallback is what keeps either node usable in a scene with no
## LevelRunner. See docs/foundation-plan.md on why `field.resource_path` and not
## a number derived from it is the evidence that an authored .tres arrived.
@export var field: TerrainField

## Material handed to the rendered surface. Shared deliberately - one material
## for the whole world means the neon look is retuned in one place.
##
## THE TWO RENDERERS NEED DIFFERENT SHADERS AND THEREFORE DIFFERENT MATERIALS.
## The clipmap's displaces vertices from a height texture and the voxel one does
## not, so pointing a clipmap at `terrain/materials/neon_terrain.tres` renders a
## flat plane at y = 0 rather than failing.
@export var surface_material: Material

## What the terrain centres its detail on, if it has any to centre. SET BY THE
## LEVEL and never found by the terrain itself: the ground does not know the
## game contains a tank, and anything that has to know about two systems is a
## level concern (see main.gd's header).
##
## Declared here rather than on the clipmap so the level can set it
## unconditionally. A terrain with no level of detail - the voxel grid - simply
## never reads it, which is a cheaper contract than `if terrain is X` at the one
## call site.
var follow_target: Node3D


## Builds the world. Synchronous by design: the level is not playable until the
## collision exists, so there is nothing useful to do with a half-built one.
func build() -> void:
	push_error("TerrainSurface.build() not implemented by %s" % get_script())


## Puts the world back to its as-built state. A no-op for a terrain that cannot
## be changed at runtime, which is not the same thing as unimplemented.
func reset() -> void:
	pass


## Height of the ORIGINAL ground at a world x/z, in world units, ignoring
## anything carved out of it afterwards. What to spawn things on.
##
## Both renderers answer from `field.ground`, so the tank, the scatter and the
## analysis all agree about where the ground is by construction. Overriding this
## to answer from meshed geometry instead would be a second answer to the same
## question - see spawner.gd's header on why there is only one.
func surface_height(x: float, z: float) -> float:
	if field == null or field.ground == null:
		return 0.0
	return field.ground.surface_height(x, z)


## Half-width of the world on X, for anything that needs to stay inside it.
func world_extent_x() -> float:
	return 0.0


func world_extent_z() -> float:
	return 0.0


## Lowest y the world covers. Anything below this has left it.
func world_floor() -> float:
	return 0.0


## Triangles currently drawn across the whole terrain. Derived from the meshes,
## not from the code that built them.
func triangle_count() -> int:
	return 0


## Independently meshed pieces the world is drawn as - chunks for the voxel
## grid, clipmap rings for the heightmap one.
func chunk_count() -> int:
	return 0


## Craters carved since the last reset. Always 0 on a terrain that cannot be
## carved.
func crater_count() -> int:
	return 0


## Whether a shell cuts a hole in this world. The HUD reads it to decide whether
## a crater count is information or dead text.
func is_destructible() -> bool:
	return false
