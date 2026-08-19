extends Node

# The level. It builds the world, puts the tank on it, wires the HUD, and owns
# what a reset means - and it is also the surface the dev harness reads state
# off, which is why so much of it is plain properties rather than accessors.
#
# WHAT LIVES HERE AND WHY. The terrain does not know about the tank; the tank
# does not know about the terrain; neither knows about the HUD. Anything that
# has to know about two of them is a level concern and lives in this file. That
# is what keeps `tank.tscn` droppable into an empty scene and `terrain.gd`
# testable without a player.

@onready var terrain: Terrain = $Terrain
@onready var tank: Tank = $Tank
@onready var ui: TankUI = $UI

## Material shared by every terrain chunk. Held here as well so trip mode has
## something to write a shader parameter to without walking the tree.
@export var terrain_material: ShaderMaterial = preload("res://terrain/materials/neon_terrain.tres")

## How far above the ground the tank is dropped in. A little height rather than
## exactly on the surface: the collision box settles in the first few frames,
## and starting it intersecting the terrain launches it.
@export var spawn_clearance: float = 4.0

## Seconds the trip-mode shader parameter takes to ramp in or out. Instant
## looks like a bug; this looks like an effect.
@export var trip_fade: float = 1.2

# ------------------------------------------------------------
# Harness-facing state
# ------------------------------------------------------------
# DevHarness gates every measurement on this flag, so nothing is read against a
# half-built tree. It must be a plain property named exactly this.
var _loading_complete: bool = false

# THESE ARE COMPUTED ON READ, NOT MIRRORED PER FRAME, AND THAT IS THE POINT.
#
# They were plain vars refreshed in _process(). A harness eval that emitted
# shell_exploded and then read `explosions_spawned` in the SAME batch got 0 -
# the effect had genuinely spawned, but no frame had run in between to copy the
# number across. The mirror reported "nothing happened" about something that
# had, which is the exact shape of wrong this pipeline exists to catch, and it
# would have been read as a broken signal connection.
#
# A getter cannot be stale. It also costs nothing when nobody is looking.

## Chunks in the terrain grid.
var chunks_total: int:
	get:
		return terrain.chunks_total if terrain != null else 0

## Triangles across the whole terrain.
##
## Note it goes UP when a crater is carved, not down: a hole has walls, and
## those walls are new surface. Measured, on a radius-8 crater at the origin:
## 28414 -> 28498. So this proves the mesh CHANGED, and is not on its own
## evidence that material was removed - for that, compare a chunk's
## get_mesh_aabb() or look at the pixels.
var terrain_triangles: int:
	get:
		return terrain.triangles_total if terrain != null else 0

## Craters carved since the last reset.
var craters_carved: int:
	get:
		return terrain.craters_carved if terrain != null else 0

## Explosions the effects director has spawned. Confirms the bus is live
## without needing pixels.
var explosions_spawned: int:
	get:
		return _explosions.explosions_spawned if _explosions != null else 0

## Where the tank was actually placed. Measured, not assumed: it is the one
## value that decides whether the run starts inside a hill or above one.
var tank_spawn_height: float = 0.0

## Trip mode, 0 or 1. Read back to confirm the toggle did anything.
var trip_active: bool = false

var _explosions: ExplosionDirector
var _trip_tween: Tween


func _ready() -> void:
	_explosions = $Effects

	terrain.surface_material = terrain_material
	terrain.build()

	_place_tank()

	ui.tank = tank
	ui.terrain = terrain

	GameEvents.level_reset_requested.connect(_on_level_reset_requested)

	# Trip mode is off at load however the material was last saved. A shader
	# parameter is part of a shared resource on disk, so leaving it wherever it
	# happened to be left is how a "temporary" debug state ships.
	terrain_material.set_shader_parameter("trip_amount", 0.0)
	# The ramp is written against the terrain's own amplitude so the neon hue
	# spans the hills rather than clipping at their tops.
	terrain_material.set_shader_parameter("height_range", terrain.field.ground.amplitude)

	# One frame, so the first measurement is taken against a tree that has
	# actually drawn rather than one that has merely been built. Everything
	# downstream - the perf sampler's gate, the harness's await - hangs off
	# this signal.
	await get_tree().process_frame
	_loading_complete = true
	GameEvents.loading_complete.emit(name)

	GameLogger.write_log("state", "loading_complete", {
		"chunks": chunks_total,
		"triangles": terrain_triangles,
		"tank_spawn_height": snappedf(tank_spawn_height, 0.01),
		"world_extent_x": terrain.world_extent_x(),
		"world_extent_z": terrain.world_extent_z(),
	})


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_trip"):
		set_trip(not trip_active)


# ------------------------------------------------------------
# Setup
# ------------------------------------------------------------
# Drops the tank on the ground at the origin rather than at a fixed height.
# The terrain is procedural, so a hardcoded spawn y is wrong the first time
# anyone changes the seed - and wrong in the worst way, either buried in a hill
# or falling out of the sky.
func _place_tank() -> void:
	var ground := terrain.surface_height(0.0, 0.0)
	tank_spawn_height = ground + spawn_clearance
	tank.spawn_position = Vector3(0.0, tank_spawn_height, 0.0)
	tank.death_height = terrain.world_floor() - 20.0
	tank.global_position = tank.spawn_position


# ------------------------------------------------------------
# Run state
# ------------------------------------------------------------
# The tank asks for a reset; the level decides what a reset restores. The tank
# has no business knowing the world contains craters.
func _on_level_reset_requested(reason: String) -> void:
	GameLogger.write_log("state", "level_reset", {
		"reason": reason,
		"craters_cleared": terrain.craters_carved,
	})

	terrain.reset()
	tank.respawn()


# ------------------------------------------------------------
# Trip mode
# ------------------------------------------------------------
## Ramps the psychedelic shader parameter in or out. Public so the harness can
## drive it: an input binding cannot be tested through --harness-eval, so the
## branch body has to be callable directly.
func set_trip(active: bool) -> void:
	trip_active = active

	if _trip_tween != null and _trip_tween.is_valid():
		_trip_tween.kill()

	_trip_tween = create_tween()
	_trip_tween.tween_method(
		func(value: float) -> void:
			terrain_material.set_shader_parameter("trip_amount", value),
		terrain_material.get_shader_parameter("trip_amount") as float,
		1.0 if active else 0.0,
		trip_fade)
