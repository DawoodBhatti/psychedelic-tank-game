extends Node
class_name LevelRunner

# The level runner. It builds the world a LevelDef describes, puts the tank on
# it, wires the HUD, and owns what a reset means - and it is also the surface
# the dev harness reads state off, which is why so much of it is plain
# properties rather than accessors.
#
# WHAT LIVES HERE AND WHY. The terrain does not know about the tank; the tank
# does not know about the terrain; neither knows about the HUD. Anything that
# has to know about two of them is a level concern and lives in this file. That
# is what keeps `tank.tscn` droppable into an empty scene and `terrain.gd`
# testable without a player.
#
# WHAT MOVED OUT, AND WHY. This script used to carry the level's VALUES too -
# which material, how much spawn clearance, how long the trip fade lasts - as
# exported constants, and the scene carried the field. They are now a LevelDef
# resource. The rule that separates them: this file is the machinery that runs
# a level, the .tres is which level it runs, so a second valley costs a new
# resource file and no new code.

@onready var terrain: TerrainSurface = $Terrain
@onready var tank: Tank = $Tank
@onready var ui: TankUI = $UI
@onready var world_environment: WorldEnvironment = $WorldEnvironment
@onready var spawner: Spawner = $Spawn

## The level to run. Everything that describes this valley rather than the
## machinery for playing it comes from here.
@export var level: LevelDef

# ------------------------------------------------------------
# Level configuration, read through rather than copied
# ------------------------------------------------------------
# These three were exported vars on this script and are now views onto the
# LevelDef. Getters rather than copies taken in _ready(), for the same reason
# the harness state below is: a copy is a second place the value lives, and the
# copy is the one that goes stale. They also keep working for anything that was
# reading them by name.

## Material shared by every terrain chunk.
var terrain_material: ShaderMaterial:
	get:
		return level.surface_material if level != null else null

## How far above the ground the tank is dropped in.
var spawn_clearance: float:
	get:
		return level.spawn_clearance if level != null else 0.0

## Seconds the trip-mode shader parameter takes to ramp in or out.
var trip_fade: float:
	get:
		return level.trip_fade if level != null else 0.0

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

## Independently meshed pieces the world is drawn as - marching-cubes chunks on
## the voxel terrain, clipmap ring levels on the heightmap one.
var chunks_total: int:
	get:
		return terrain.chunk_count() if terrain != null else 0

## Triangles currently drawn across the whole terrain, read off the meshes
## rather than off the code that built them.
##
## ON THE VOXEL TERRAIN it goes UP when a crater is carved, not down: a hole has
## walls, and those walls are new surface. Measured on the 8x3x8 grid, with
## Terrain.destructible flipped on at runtime and a radius-8 crater dropped on
## the surface at the origin: 95058 -> 95206. So it proves the mesh CHANGED, and
## is not on its own evidence that material was removed.
##
## ON THE CLIPMAP it is constant after the build - the meshes are never rebuilt
## and every hole-position variant of a ring carries the same triangle count, so
## the number does not move as the world slides under the player. That is a
## property worth checking rather than assuming.
var terrain_triangles: int:
	get:
		return terrain.triangle_count() if terrain != null else 0

## Craters carved since the last reset. Always 0 on a terrain that cannot be
## carved, which is every terrain the game currently runs.
var craters_carved: int:
	get:
		return terrain.crater_count() if terrain != null else 0

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

# --- Scatter ---------------------------------------------------------------
# Where the entity layer put its mass. A transform is a CLAIM about intent
# unless something measures the gap it left, and none of the six tests in the
# sequence asks where anything is - so a generator that decides where mass lands
# owes a clearance, the same way Terrain.last_carve_clearance does for carving.
#
# All getters, for the reason above. spawn_failures in particular: it is written
# once during the level build and never again, so a per-frame mirror of it would
# be correct in every situation except the one where someone re-ran the scatter
# and asked in the same batch.

## Entities the scatter could not find a home for. THE SESSION GATE IS ZERO.
##
## -1, not 0, when there is no Spawner at all: a missing spawner placing nothing
## must not report the same number as a scatter that placed everything it was
## asked to. A sentinel that fails the gate is the only safe answer to "I could
## not measure this".
var spawn_failures: int:
	get:
		return spawner.spawn_failures if spawner != null else -1

## Entities actually placed. Read WITH spawn_failures: zero failures out of zero
## requested is not evidence of anything.
var entities_spawned: int:
	get:
		return spawner.entities_placed if spawner != null else -1

## Smallest gap between any two placed entities, or between one and the player's
## spawn, after subtracting the separation each was placed under. Positive means
## nothing overlaps anything it was told to keep off; zero or below means the
## overlap rejection did not do its job.
##
## INF when there is nothing to measure - pair it with entities_spawned.
var min_spawn_clearance: float:
	get:
		return spawner.min_spawn_clearance() if spawner != null else INF

## Smallest distance from a placed entity down to the ground beneath it. This is
## what says the surface snap actually happened, and it is derived DIFFERENTLY
## from the placement - live node transform minus a fresh surface_height() at
## that node's own x/z - so reading it is a check and not a re-execution.
var min_ground_clearance: float:
	get:
		return spawner.min_ground_clearance() if spawner != null else INF

## Placed entities carrying a Damageable that has not been destroyed, and the
## number that carry one at all. Counted off the live nodes, so a kill shows up
## here without anything having to remember it happened.
##
## RENAMED FROM enemies_alive / enemies_total IN S4, and it is a rename rather
## than a second pair: the only thing the manifest scatters now is towers, and a
## counter called "enemies" that counts scenery is a name that lies. Nothing is
## freed on death - Tower keeps its wreck standing - so `towers_alive` moves off
## `Damageable.is_alive` and `towers_total` does not move at all. Read the two
## together: 6 of 6 and 0 of 0 both report "nothing has died".
##
## THE CONCEPT WAS NOT DELETED, ONLY THIS USE OF IT. S4c puts enemy tanks back
## on the ENEMIES layer and will want its own count, which is why
## `Spawner.live_damageable_count()` and `damageable_count()` keep their general
## names and their general behaviour - they count any Damageable, and splitting
## them by category is that session's problem, not this one's.
##
## S4C SPLIT THEM, and by TYPE rather than by group id - see the Spawner's own
## note on why a mistyped string filter reports "0 of 0" and passes. These two
## now count towers ONLY, so five-hits-to-kill stays testable after a red tank
## dies.
var towers_alive: int:
	get:
		return spawner.live_damageable_count(Tower) if spawner != null else 0

var towers_total: int:
	get:
		return spawner.damageable_count(Tower) if spawner != null else 0

## The red tanks, counted the same way and SEPARATELY. Same pairing rule as the
## towers: read alive WITH total, because 0 of 0 and 4 of 4 both mean "nothing
## has died" and only one of them means the level has enemies in it.
##
## Nothing is freed on death - a killed red tank stays as a wreck, exactly as a
## destroyed tower stays standing - so `enemies_alive` moves off
## `Damageable.is_alive` and `enemies_total` does not move at all.
var enemies_alive: int:
	get:
		return spawner.live_damageable_count(EnemyTank) if spawner != null else 0

var enemies_total: int:
	get:
		return spawner.damageable_count(EnemyTank) if spawner != null else 0

# --- Patrol containment ----------------------------------------------------
# WHERE THE AI PUT ITS TANKS OVER TIME, which is the same kind of unanswerable
# question the scatter clearances above exist for and needs the same kind of
# answer. A position is a claim about one instant; nothing in the test sequence
# asks where anything went; and no frame runs inside a --harness-eval batch, so
# a patrol that quietly wanders off cannot be caught by reading a transform.
#
# The enemies accumulate the numbers in _physics_process, on the code path that
# writes them; these are getters over the live nodes, so they cannot go stale.

## Smallest margin any red tank had left inside its own patrol circle - its
## radius minus the furthest it ever got from its centre while patrolling.
## Positive means every patrol stayed inside its patch by that much.
##
## INF when there are no enemies at all, so READ IT WITH `patrol_frames_sampled`
## and `enemies_total`: a clearance measured over nothing passes any threshold
## put on it, which is the same trap `min_spawn_clearance` is paired with
## `entities_spawned` against.
var min_patrol_clearance: float:
	get:
		var worst := INF
		for node in _enemies():
			worst = minf(worst, node.patrol_clearance())
		return worst

## Fewest physics frames any one red tank contributed to the number above. Zero
## means at least one of them was never sampled, and its clearance is therefore
## its full radius for no reason at all.
var patrol_frames_sampled: int:
	get:
		var fewest := 0
		var first := true
		for node in _enemies():
			fewest = node.patrol_frames if first else mini(fewest, node.patrol_frames)
			first = false
		return fewest

## Times any red tank has gone from patrolling to engaging, and back again.
##
## THESE ARE THE ONLY THING THAT SAYS THE STATE MACHINE CONSULTS ITS SENSES.
## `EnemyTank.can_see()` can be called directly and proves the predicate; it does
## not prove anything reads it. These move only inside the transition, so a run
## with the player parked in view and `enemy_aggro_transitions` still at 0 is a
## machine ignoring its own eyes.
var enemy_aggro_transitions: int:
	get:
		var total := 0
		for node in _enemies():
			total += node.aggro_transitions
		return total

var enemy_leash_transitions: int:
	get:
		var total := 0
		for node in _enemies():
			total += node.leash_transitions
		return total

## Smallest gap between any world-space health bar and the geometry it hangs
## over. Positive means every bar clears its entity by that much; zero or below
## means one is buried inside the thing it describes.
##
## THE SAME ARGUMENT AS min_ground_clearance, applied to the other thing this
## session places: a bar's transform is a claim about where it is until something
## measures the gap it left, and no test in the sequence asks. A bar sunk into a
## tower's cap renders, passes the render check and is unreadable in play.
##
## INF when there are no bars at all - pair it with towers_total, exactly as
## min_spawn_clearance is paired with entities_spawned. A getter rather than a
## var for the reason the block above gives.
var min_health_bar_clearance: float:
	get:
		var worst := INF
		for bar in _health_bars(self):
			worst = minf(worst, bar.clearance())
		return worst

var _explosions: ExplosionDirector
var _trip_tween: Tween


func _ready() -> void:
	if level == null:
		# Loud, then keep going on defaults. A level with no LevelDef builds a
		# default hills world rather than a black screen, and the error is what
		# says why it does not look like the valley.
		push_error("LevelRunner: no LevelDef assigned - running on defaults")
		level = LevelDef.new()

	_explosions = $Effects

	_apply_level()
	terrain.build()

	_place_tank()
	_scatter_entities()
	_wire_enemies()

	ui.tank = tank
	ui.terrain = terrain

	GameEvents.level_reset_requested.connect(_on_level_reset_requested)
	GameEvents.entity_destroyed.connect(_on_entity_destroyed)

	# Trip mode is off at load however the material was last saved. A shader
	# parameter is part of a shared resource on disk, so leaving it wherever it
	# happened to be left is how a "temporary" debug state ships.
	terrain_material.set_shader_parameter("trip_amount", 0.0)
	# The ramp is written against the terrain's own vertical extent so the neon
	# hue spans the hills rather than clipping at their tops. Asked of the FIELD
	# every load rather than stored on the LevelDef: a number copied into level
	# data goes stale the first time the field is retuned, and a hue ramp is not
	# something any test in the sequence looks at.
	terrain_material.set_shader_parameter("height_range", terrain.field.ground.vertical_extent())

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
		"entities_spawned": entities_spawned,
		"spawn_failures": spawn_failures,
	})


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_trip"):
		set_trip(not trip_active)


# The red tanks the scatter placed, typed. Asked of the Spawner rather than
# walked, because they are placed entities and the Spawner is what knows which
# nodes it placed.
func _enemies() -> Array[EnemyTank]:
	var out: Array[EnemyTank] = []
	if spawner == null:
		return out
	for node in spawner.placed(EnemyTank):
		out.append(node as EnemyTank)
	return out


# Every HealthBar3D anywhere under `node`. Walked rather than asked of the
# Spawner, because the spawner is not the only thing that can own one - the
# clearance above should keep answering when S4c hangs a bar on something placed
# a different way.
func _health_bars(node: Node) -> Array[HealthBar3D]:
	var out: Array[HealthBar3D] = []
	for child in node.get_children():
		if child is HealthBar3D:
			out.append(child)
		out.append_array(_health_bars(child))
	return out


# ------------------------------------------------------------
# Setup
# ------------------------------------------------------------
# Pushes the level's data into the nodes that render it, before anything is
# built from it.
#
# Terrain._ready() has already run by now - children are ready before their
# parent - so a Terrain left with no field in the scene has built itself a
# default one, which this discards. That fallback is what keeps terrain.gd
# usable in a scene with no LevelRunner at all; here it costs one throwaway
# noise object and no meshing, because build() has not run yet.
func _apply_level() -> void:
	if level.field != null:
		terrain.field = level.field
	terrain.surface_material = terrain_material

	# The clipmap keeps its finest ring under the player, so it needs to know
	# where the player is - and the terrain must not go looking for a tank. This
	# is the same division of labour that puts _place_tank() in this file: two
	# systems have to be introduced, and the level is what knows both.
	terrain.follow_target = tank

	if level.environment != null:
		world_environment.environment = level.environment


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


# Populates the valley from the level's spawn manifest.
#
# AFTER _place_tank(), and that ordering is load-bearing: the tank's spawn is
# reserved before anything else is placed, so the player never starts the run
# inside a guardian. The spawner has no idea where the player begins and should
# not - the level does, which is the same division of labour that put the tank's
# own placement in this file rather than in tank.gd.
#
# It does not re-mesh anything. terrain.build() has already run and every chunk
# has its collider; placement only asks the field for heights.
func _scatter_entities() -> void:
	spawner.reserve(tank.spawn_position, level.player_keepout)
	spawner.scatter(terrain, level.spawn_manifest, level.spawn_seed)


# Introduces the red tanks to the thing they hunt.
#
# THE LEVEL DOES THIS, NOT THE ENEMY, and it is the same division of labour that
# hands the terrain its follow_target two functions up: an enemy that went
# looking for the player would have to know the game contains one, and this
# file's header exists to keep that knowledge in one place. It is also what keeps
# enemy_tank.tscn droppable into a scene with no player in it - the target simply
# stays null and it patrols.
#
# AFTER _scatter_entities(), necessarily: there is nothing to wire until the
# spawner has placed them. Before the first physics frame, so no enemy ever runs
# a frame with a null target it could have had.
func _wire_enemies() -> void:
	for enemy in _enemies():
		enemy.target = tank


# ------------------------------------------------------------
# Run state
# ------------------------------------------------------------
# The tank asks for a reset; the level decides what a reset restores. The tank
# has no business knowing the world contains craters.
func _on_level_reset_requested(reason: String) -> void:
	GameLogger.write_log("state", "level_reset", {
		"reason": reason,
		"craters_cleared": terrain.crater_count(),
	})

	terrain.reset()
	tank.respawn()


# A kill patches the player up, and THE LEVEL IS WHAT DECIDES THAT.
#
# Not the tank: a tank that knows killing heals it has to know what an enemy is,
# which is the coupling this file's header exists to prevent. Not the tower
# either - a tower that knows what its own death is worth to the player could not
# be dropped into a level that does not reward kills without being edited. The
# level knows both parties and owns the rule; `level.kill_heal` is the number.
#
# The bus rather than a per-entity connection, so nothing has to be re-wired when
# S4c scatters something else killable: entity_destroyed already fires exactly
# once per death and already carries who died.
func _on_entity_destroyed(entity: Node3D, _source: Node3D) -> void:
	# The player's own death is not a kill. Without this the tank heals itself to
	# full on the frame it is destroyed, which reads as a tank that cannot die.
	if entity == tank or tank == null or tank.damageable == null:
		return
	if level.kill_heal <= 0.0:
		return

	var restored := tank.damageable.heal(level.kill_heal)
	GameLogger.write_log("state", "kill_heal", {
		"entity": entity.name,
		"restored": snappedf(restored, 0.01),
		"health": snappedf(tank.damageable.health, 0.01),
	})


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
