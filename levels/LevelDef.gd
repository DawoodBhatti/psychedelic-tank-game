extends Resource
class_name LevelDef

# A level as DATA. Everything that says WHICH level is being played, separated
# from LevelRunner, which is the machinery that plays one.
#
# The split follows the doctrine main.gd already stated - anything that has to
# know about two systems is a level concern - and moves it one step further: a
# level concern that is a VALUE belongs in a .tres, not in an exported constant
# on a script. A second level then costs a new resource file and no new code,
# which is the point of the whole exercise.
#
# The test for whether something belongs here: would the next level plausibly
# want a different value? The chunk grid (resolution, voxel size, chunk counts)
# deliberately stays on the Terrain node, because it is a cost/fidelity dial for
# the renderer rather than a description of this valley.
#
# DELIBERATELY NOT HERE YET. Spawn manifests and objectives are named in
# docs/foundation-plan.md under this resource, and are sessions D and G. They
# are absent rather than stubbed, so nothing later has to work around an empty
# shape guessed before the systems that fill it exist.

## The world's density field, craters included. Handed to the Terrain node
## before it builds, which is why the .tscn no longer carries one: two places
## naming the field is two places to disagree about which valley this is.
@export var field: TerrainField

## Material every terrain chunk shares. Shared deliberately - one material for
## the whole world means the neon look is retuned in one place - and held here
## as well so trip mode has something to write a shader parameter to without
## walking the tree.
@export var surface_material: ShaderMaterial

## Sky, fog and tonemapping, applied to the level's WorldEnvironment.
@export var environment: Environment

## How far above the ground the tank is dropped in. A little height rather than
## exactly on the surface: the collision box settles in the first few frames,
## and starting it intersecting the terrain launches it.
@export var spawn_clearance: float = 4.0

## Seconds the trip-mode shader parameter takes to ramp in or out. Instant
## looks like a bug; this looks like an effect.
@export var trip_fade: float = 1.2
