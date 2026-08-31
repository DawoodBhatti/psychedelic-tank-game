extends Node3D
class_name Spawner

# Puts things on the ground, in places that make sense, without overlapping.
#
# WHAT IT GENERALISES. LevelRunner._place_tank() is three lines: ask the terrain
# for the surface height at a point, add a clearance, put the tank there. That
# is correct and it is the whole of what a spawner does for ONE entity at ONE
# known position. Everything here is what the other two words in the plan cost -
# "clearance-check" and "reject overlaps" - plus choosing the position at all,
# which for a procedural valley cannot be authored as a coordinate.
#
# THE SURFACE SNAP IS STILL THAT SAME THREE LINES, and deliberately: placement
# reads Terrain.surface_height(), the identical call the tank's placement uses,
# so the tank and everything scattered around it agree about where the ground
# is. A second way of asking would be a second answer.
#
# IT DOES NOT RE-MESH ANYTHING. No generate(), no rebuild(), no carve. Chunks
# already have their colliders by the time this runs and calling generate() on
# one a second time stacks a second StaticBody3D on the first (see CLAUDE.md).
# Placement only ever asks the field for heights.
#
# OVERLAP REJECTION IS ANALYTIC, NOT A PHYSICS QUERY, and that is not laziness.
# Bodies added to the tree in the current frame are not in the physics server's
# broadphase until it steps, so intersect_shape() against the entity placed a
# microsecond ago returns nothing - an overlap check that passes everything,
# every time, and looks exactly like an overlap check that works. Distance
# between recorded positions has no such frame dependency.
#
# DETERMINISM. Candidate jitter and the order the pool is walked both come from
# the level's spawn_seed, so the same level lays out the same way every launch.
# That is what lets a before/after screenshot of anything else in the project
# stay pixel-comparable, and it is why the shuffle below is written out by hand
# instead of using Array.shuffle(), which draws from the global RNG.

## Candidates along each axis of the analysis grid; the pool is this squared.
## The pool is shared by every group, so this is the resolution at which the
## whole manifest can distinguish one piece of ground from another.
@export var candidates_per_axis: int = 20

## Sightline settings, handed to TerrainAnalysis. See that file for what each
## one costs: openness is directions * steps height samples per candidate and is
## by far the most expensive part of the pass.
@export var sightline_range: float = 60.0
@export var sightline_directions: int = 8
@export var sightline_steps: int = 8
@export var eye_height: float = 2.0

## Candidates are kept this far inside the world edge.
@export var edge_margin: float = 6.0

# ------------------------------------------------------------
# Harness-facing state
# ------------------------------------------------------------
# These two are RECORDED ON THE CODE PATH THAT WRITES THEM - incremented inside
# scatter() - not mirrored in _process(). LevelRunner exposes both through
# getters for the reason main.gd:62 sets out at length: a value copied per frame
# reports its pre-batch number to any harness eval that changed it, which reads
# as "nothing happened" about something that did.

## Entities this spawner failed to find a home for. THE SESSION GATE IS THAT
## THIS IS ZERO. A scatter that cannot satisfy a rule carries on rather than
## crashing, which is precisely the silent-wrong-number failure this pipeline
## exists to catch, so it gets a number of its own.
var spawn_failures: int = 0

## Entities actually placed. Read alongside spawn_failures: zero failures out of
## zero requested is not a pass, and the clearances below are undefined when
## nothing was placed.
var entities_placed: int = 0

## Per-group outcome, written once per group during the scatter: requested,
## placed, and a tally of rejections by criterion.
##
## READ THE TALLY AS A HINT, NOT AS A CENSUS. Two things make it an undercount,
## both deliberate and neither worth removing:
##
##   - rejected_by() returns the FIRST criterion a candidate fails, in the order
##     slope, elevation, openness, edge. A candidate failing three of them is
##     counted once, against the earliest. So `"openness": 1` means "openness
##     was the first thing one candidate failed", not "openness cost us one".
##   - the walk stops as soon as the group is full, so the tally describes only
##     the candidates examined - 32 of 400 for a group that filled early - not
##     the pool.
##
## It is still the fastest way to see WHICH bound is worth suspecting when a
## group comes up short, which is all it is for. To measure a bound properly,
## compare it against the quantiles in `terrain_metrics`.
var group_reports: Array[Dictionary] = []

## TerrainAnalysis.metrics_summary() for this level's candidate pool - the
## measured quantiles every threshold in the manifest should be sitting between.
var terrain_metrics: Dictionary = {}

var _terrain: TerrainSurface

# Placed entities and the separation each was placed under, index-aligned.
# Nodes rather than positions, so the clearance getters read the LIVE transform:
# a number derived from what placement intended is not evidence about where
# anything ended up.
var _placed_nodes: Array[Node3D] = []
var _placed_separation := PackedFloat32Array()

# Points nothing may be placed near - the tank's spawn, above all.
var _reserved_pos := PackedVector3Array()
var _reserved_radius := PackedFloat32Array()


## Declares a keep-out around a point. Called before scatter(); the level knows
## where the player starts and the spawner does not.
##
## ACCUMULATES, and scatter() deliberately does NOT clear reservations - they
## describe the level rather than the run, and a caller that re-scatters wants
## the player's spawn still protected. Call it once per point, not once per
## scatter, or the same keep-out is recorded twice. Duplicates are harmless
## (identical constraints), merely wasteful.
func reserve(centre: Vector3, radius: float) -> void:
	_reserved_pos.push_back(centre)
	_reserved_radius.push_back(radius)


# Everything scatter() has to undo before it runs again. THE ARRAYS MATTER AS
# MUCH AS THE COUNTERS: a second scatter() that reset spawn_failures but kept
# _placed_nodes would leave the previous run's entities in the tree, measure
# every clearance against them, and reject candidates for overlapping things
# that no longer belong to this run.
#
# This is the same shape as CLAUDE.md's generate()/rebuild() trap - a function
# that is only safe to call once and does not say so - and the fix here is the
# cheaper direction: make it safe to call twice rather than document that it is
# not. Nothing calls scatter() twice today; a level reset is the obvious thing
# that will.
#
# remove_child before queue_free, not queue_free alone: queue_free defers to the
# end of the frame, so the old entities would still be children while the new
# ones are added, "guardian_0" would still be taken, and Godot would silently
# rename the new node - breaking every node path a harness eval uses.
func _clear_placed() -> void:
	for node in _placed_nodes:
		if is_instance_valid(node):
			remove_child(node)
			node.queue_free()
	_placed_nodes.clear()
	_placed_separation.clear()


## Places the whole manifest. Synchronous, like terrain.build() and for the same
## reason: there is nothing useful to do with a half-populated level.
func scatter(terrain: TerrainSurface, manifest: Array[SpawnGroup], scatter_seed: int) -> void:
	_terrain = terrain
	spawn_failures = 0
	entities_placed = 0
	group_reports = []
	_clear_placed()

	if terrain == null:
		push_error("Spawner.scatter(): no terrain - nothing can be placed")
		return

	var start_usec := Time.get_ticks_usec()

	var analysis := TerrainAnalysis.new(terrain, candidates_per_axis, scatter_seed)
	analysis.sight_range = sightline_range
	analysis.sight_directions = sightline_directions
	analysis.sight_steps = sightline_steps
	analysis.eye_height = eye_height
	analysis.margin = edge_margin
	analysis.analyse()

	terrain_metrics = analysis.metrics_summary()

	for group_index in manifest.size():
		var group: SpawnGroup = manifest[group_index]
		if group == null:
			# A null slot is a layer of the level silently not being there, the
			# same failure SDFComposite.layer_count() exists to expose. Counted
			# as a failure rather than skipped quietly.
			push_error("Spawner: manifest slot %d is null" % group_index)
			spawn_failures += 1
			continue
		_scatter_group(group, group_index, analysis, scatter_seed)

	var elapsed_ms := (Time.get_ticks_usec() - start_usec) / 1000.0
	GameLogger.write_log("state", "entities_scattered", {
		"placed": entities_placed,
		"failures": spawn_failures,
		"groups": group_reports,
		"min_spawn_clearance": snappedf(min_spawn_clearance(), 0.001),
		"min_ground_clearance": snappedf(min_ground_clearance(), 0.001),
		"terrain_metrics": terrain_metrics,
		"scatter_ms": snappedf(elapsed_ms, 0.1),
	})


# Walks the shared candidate pool in a per-group shuffled order, taking the
# first `count` points that satisfy both the rule and the separation.
#
# WALKING THE POOL RATHER THAN DRAWING RANDOM ATTEMPTS is what makes a failure
# mean something. A fixed number of random tries can miss a position that
# exists, so "failed" would mean "unlucky" as often as "impossible"; exhausting
# the pool means the only ground the analysis knows about genuinely does not
# satisfy the rule.
func _scatter_group(group: SpawnGroup, group_index: int, analysis: TerrainAnalysis,
		scatter_seed: int) -> void:
	var rng := RandomNumberGenerator.new()
	# Offset per group so two groups do not walk the pool in the same order and
	# fill from the same end of it.
	rng.seed = scatter_seed + group_index * 7919

	var order := _shuffled_indices(analysis.count(), rng)
	var rejections := {}
	var placed := 0

	for candidate in order:
		if placed >= group.count:
			break

		var p := analysis.positions[candidate]

		if group.placement != null:
			var reason: String = group.placement.rejected_by(
				analysis.slope_degrees[candidate],
				analysis.elevation_percentile[candidate],
				analysis.openness[candidate],
				analysis.edge_fraction[candidate])
			if not reason.is_empty():
				rejections[reason] = int(rejections.get(reason, 0)) + 1
				continue

		if not _is_clear(p, group.separation):
			rejections["overlap"] = int(rejections.get("overlap", 0)) + 1
			continue

		_place(group, p, rng, placed)
		placed += 1

	var failed: int = maxi(group.count - placed, 0)
	spawn_failures += failed

	if failed > 0:
		# Loud, and with the tally attached: "6 requested, 2 placed" says only
		# that something is wrong, while the tally points at which bound to
		# suspect first. See group_reports for why it is a hint and not a count.
		push_error("Spawner: group '%s' placed %d of %d (rejections: %s)"
			% [group.id, placed, group.count, JSON.stringify(rejections)])

	group_reports.append({
		"id": group.id,
		"requested": group.count,
		"placed": placed,
		"failed": failed,
		"rejections": rejections,
	})


# THE SURFACE SNAP. Deliberately re-asks terrain.surface_height() rather than
# reusing the height the analysis cached: the analysis samples a jittered point
# and this is the same point, so the two agree - but making the snap read the
# field directly means the placement a node ends up at is derived from the same
# function the tank's placement uses, and can be checked against it from the
# harness without trusting anything in this file.
func _place(group: SpawnGroup, point: Vector3, rng: RandomNumberGenerator,
		index: int) -> void:
	var instance := group.scene.instantiate() as Node3D
	if instance == null:
		push_error("Spawner: group '%s' scene is not a Node3D" % group.id)
		spawn_failures += 1
		return

	# Index WITHIN THE GROUP, not the global placed count. Both are unique, but
	# the global one makes the first prop "prop_5" whenever five guardians were
	# placed first, and a node path is something a person types.
	instance.name = "%s_%d" % [group.id, index]
	add_child(instance)

	var ground := _terrain.surface_height(point.x, point.z)
	instance.global_position = Vector3(point.x, ground + group.ground_clearance, point.z)

	if group.random_yaw:
		instance.rotation.y = rng.randf_range(-PI, PI)

	_placed_nodes.append(instance)
	_placed_separation.push_back(group.separation)
	entities_placed += 1


# Separation is symmetric: the requirement between two entities is the LARGER of
# the two separations they were placed under, so a group that declares itself
# small cannot be squeezed against one that declares itself large.
func _is_clear(point: Vector3, separation: float) -> bool:
	for i in _reserved_pos.size():
		var required: float = maxf(_reserved_radius[i], separation)
		if _flat_distance(point, _reserved_pos[i]) < required:
			return false

	for i in _placed_nodes.size():
		var other := _placed_nodes[i]
		if not is_instance_valid(other):
			continue
		var required: float = maxf(_placed_separation[i], separation)
		if _flat_distance(point, other.global_position) < required:
			return false

	return true


# ------------------------------------------------------------
# Clearances - computed on read
# ------------------------------------------------------------
# WHAT THESE ARE FOR. Where a generator put mass is not readable back any other
# way: a transform is a claim about intent unless something measures the gap it
# left. Terrain.last_carve_clearance already does this for carving; these do it
# for placement. Both are computed from the LIVE node transforms at the moment
# they are asked, so neither can be stale and neither costs anything when nobody
# asks.

## Smallest gap, over every pair of placed entities and every reserved point, of
## (distance apart) minus (separation required). Positive means every placement
## respects its separation with that much room to spare; zero or negative means
## something is overlapping something it was supposed to stay off.
##
## INF when fewer than two things are in play - there is no gap to measure. Read
## `entities_placed` alongside it: INF from an empty scatter would otherwise
## pass any threshold put on this.
func min_spawn_clearance() -> float:
	var worst := INF

	for i in _placed_nodes.size():
		var node := _placed_nodes[i]
		if not is_instance_valid(node):
			continue
		var pos := node.global_position

		for r in _reserved_pos.size():
			var required: float = maxf(_reserved_radius[r], _placed_separation[i])
			worst = minf(worst, _flat_distance(pos, _reserved_pos[r]) - required)

		for j in range(i + 1, _placed_nodes.size()):
			var other := _placed_nodes[j]
			if not is_instance_valid(other):
				continue
			var required: float = maxf(_placed_separation[i], _placed_separation[j])
			worst = minf(worst, _flat_distance(pos, other.global_position) - required)

	return worst


## Smallest distance from a placed entity's origin down to the ORIGINAL ground
## beneath it. This is the number that says the surface snap happened: a group
## placed at a fixed height instead of on the terrain reads here as a spread of
## values including negative ones, and a snap that silently returned 0.0
## everywhere reads as the terrain height negated.
##
## Derived differently from the placement itself - node transform minus a fresh
## terrain.surface_height() at the node's own x/z - so re-reading it is a check
## rather than a re-execution of the code that placed things.
##
## It ignores craters, because surface_height() does: it measures the placement,
## not the state of the ground after a battle.
func min_ground_clearance() -> float:
	if _terrain == null:
		return INF

	var worst := INF
	for node in _placed_nodes:
		if not is_instance_valid(node):
			continue
		var pos := node.global_position
		worst = minf(worst, pos.y - _terrain.surface_height(pos.x, pos.z))
	return worst


## Placed entities still in the tree, counted live rather than remembered. It
## differs from `entities_placed` exactly when something has been freed.
func live_entity_count() -> int:
	var live := 0
	for node in _placed_nodes:
		if is_instance_valid(node):
			live += 1
	return live


## Placed entities carrying a Damageable that has not been destroyed.
func live_damageable_count() -> int:
	var live := 0
	for node in _placed_nodes:
		if not is_instance_valid(node):
			continue
		var d := Damageable.of(node)
		if d != null and d.is_alive:
			live += 1
	return live


## Placed entities carrying a Damageable at all, alive or not.
func damageable_count() -> int:
	var total := 0
	for node in _placed_nodes:
		if is_instance_valid(node) and Damageable.of(node) != null:
			total += 1
	return total


# Distance in the XZ plane. Separation is a footprint question: two things a
# metre apart on a cliff face are still a metre apart as far as driving into
# them is concerned.
func _flat_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


# Fisher-Yates against a LOCAL RandomNumberGenerator. Array.shuffle() draws from
# the global RNG, which is seeded from the system clock, so a level using it
# would lay out differently on every launch and no screenshot of it could be
# compared with any other.
func _shuffled_indices(n: int, rng: RandomNumberGenerator) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(n)
	for i in n:
		out[i] = i
	for i in range(n - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp := out[i]
		out[i] = out[j]
		out[j] = tmp
	return out
