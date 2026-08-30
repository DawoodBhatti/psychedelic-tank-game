extends RefCounted
class_name TerrainAnalysis

# Reads the shape of the valley, once, so that placement rules can be DATA.
#
# The foundation plan's promise: guardians go on ridgelines with long sightlines,
# cores in hollows, the gate on flat ground near an edge, props on mid-slopes.
# None of that is expressible as a coordinate. All of it is expressible as a
# range over three numbers, and this is the pass that computes those three
# numbers for a grid of candidate points:
#
#   slope             - degrees from horizontal, by central difference
#   elevation percentile - rank of this point's height among all candidates
#   openness          - mean unobstructed fraction of the sightline range
#
# WHY PERCENTILE AND NOT HEIGHT. "High ground" is relative. A rule written as
# `height > 6.0` is correct for exactly one field and silently places nothing
# the first time the amplitude is retuned or the DEM lands in session C - and
# placing nothing is the failure mode this whole layer exists to make visible. A
# percentile means "the top third of THIS valley" whatever this valley is.
#
# WHY IT READS THE FIELD AND NOT THE COLLIDERS. Terrain.surface_height() is
# closed form: one fBm evaluation, no physics, no frame required. Raycasting
# would need the physics server to have stepped, which at level-build time it
# has not, and a raycast that finds nothing looks exactly like open ground.
# The cost of the closed form is why openness can afford 64 samples a point.
#
# IT ALSO MEANS CRATERS ARE INVISIBLE HERE, by construction: surface_height() is
# the height of the ORIGINAL ground (see SDFHills.surface_height). This is the
# right answer for placement at load and the wrong one for anything deciding
# where to put something after a battle has rearranged the ground.
#
# NOTHING HERE TOUCHES THE CHUNK GRID. No generate(), no rebuild() - it only
# asks the field for heights, so an analysis pass cannot stack a second collider
# on a chunk (see CLAUDE.md's trap about generate() vs rebuild()).

## Half the sample spacing used for the slope's central difference. Defaults to
## one voxel, so slope is measured at the scale the mesh can actually resolve
## rather than at a scale finer than the terrain exists at.
var slope_step: float = 2.0

## How far a sightline reaches before the point counts as fully open.
var sight_range: float = 60.0

## Compass directions cast per point. 8 is every 45 degrees.
var sight_directions: int = 8

## Samples along each sightline. Cost is directions * steps per candidate.
var sight_steps: int = 8

## Height above the surface the sightline starts from - roughly a turret. At 0
## every point on a slope occludes itself and openness collapses to noise.
var eye_height: float = 2.0

## Candidates are kept this far inside the world edge, so nothing is offered a
## position half of which is outside the meshed volume.
var margin: float = 6.0

# --- Results, parallel and index-aligned ---------------------------------
# Packed arrays for the reason TerrainField gives for its crater arrays: these
# are walked repeatedly and an untyped Array boxes every element into a Variant
# on read. Index-aligned rather than an Array of Dictionaries for the same
# reason SDFComposite keeps its plan arrays aligned - one index, one candidate,
# nothing to get out of step.

## Candidate surface positions: x and z are the sample, y is the ground height.
var positions := PackedVector3Array()

## Slope in DEGREES from horizontal at each candidate.
var slope_degrees := PackedFloat32Array()

## Openness at each candidate, 0 (boxed in) to 1 (nothing within sight_range
## rises above eye level in any direction).
var openness := PackedFloat32Array()

## Rank of each candidate's height among all candidates, 0 (lowest) to 1
## (highest).
var elevation_percentile := PackedFloat32Array()

## Distance to the nearest world edge as a fraction of the half-extent: 0 at the
## edge, 1 dead centre. This is the "near a map edge" in the plan's gate rule.
var edge_fraction := PackedFloat32Array()

var _terrain: TerrainSurface
var _per_axis: int
var _seed: int


func _init(terrain: TerrainSurface, per_axis: int = 20, analysis_seed: int = 0) -> void:
	_terrain = terrain
	_per_axis = maxi(per_axis, 2)
	_seed = analysis_seed


## Number of candidate points. Read this rather than assuming per_axis squared.
func count() -> int:
	return positions.size()


## Builds the candidate set and every metric over it. Call once; the Spawner
## then filters the same pool for every group, which is what makes two groups
## with the same rule land on the same kind of ground.
func analyse() -> void:
	_build_candidates()
	_measure()
	_rank_elevation()


# A JITTERED grid, not a plain one. A plain grid puts every candidate on a
# lattice of the same spacing as the noise, which correlates the sample set with
# the terrain that generated it - and, worse here, lands points on the integer
# coordinates where Perlin noise is exactly zero. The jitter is deterministic
# from the seed, so a run is reproducible.
func _build_candidates() -> void:
	positions = PackedVector3Array()

	var rng := RandomNumberGenerator.new()
	rng.seed = _seed

	var ext_x: float = _terrain.world_extent_x() - margin
	var ext_z: float = _terrain.world_extent_z() - margin
	if ext_x <= 0.0 or ext_z <= 0.0:
		push_error("TerrainAnalysis: margin %.1f leaves no room inside the world" % margin)
		return

	var step_x := (ext_x * 2.0) / float(_per_axis)
	var step_z := (ext_z * 2.0) / float(_per_axis)

	for ix in _per_axis:
		for iz in _per_axis:
			var x := -ext_x + (ix + 0.5) * step_x + rng.randf_range(-0.45, 0.45) * step_x
			var z := -ext_z + (iz + 0.5) * step_z + rng.randf_range(-0.45, 0.45) * step_z
			x = clampf(x, -ext_x, ext_x)
			z = clampf(z, -ext_z, ext_z)
			positions.push_back(Vector3(x, _terrain.surface_height(x, z), z))


func _measure() -> void:
	var n := positions.size()
	slope_degrees.resize(n)
	openness.resize(n)
	edge_fraction.resize(n)

	var ext_x: float = _terrain.world_extent_x()
	var ext_z: float = _terrain.world_extent_z()

	for i in n:
		var p := positions[i]
		slope_degrees[i] = _slope_at(p.x, p.z)
		openness[i] = _openness_at(p.x, p.z, p.y)
		edge_fraction[i] = minf(
			1.0 - absf(p.x) / ext_x,
			1.0 - absf(p.z) / ext_z)


# Gradient magnitude by central difference, turned into an angle. atan of the
# gradient rather than the gradient itself so a rule reads in degrees, which is
# the unit the tank's own floor_max_angle is already expressed in.
func _slope_at(x: float, z: float) -> float:
	var d := slope_step
	var dx := (_terrain.surface_height(x + d, z) - _terrain.surface_height(x - d, z)) / (2.0 * d)
	var dz := (_terrain.surface_height(x, z + d) - _terrain.surface_height(x, z - d)) / (2.0 * d)
	return rad_to_deg(atan(sqrt(dx * dx + dz * dz)))


# Walks outward in `sight_directions` compass directions and records how far
# each gets before the ground rises above eye level. The mean, normalised by the
# range, is openness: a ridge crest sees a long way in every direction and
# scores near 1; the bottom of a hollow is cut off in every direction and scores
# near 0.
#
# Leaving the world counts as CLEAR, not blocked. The alternative makes every
# point near an edge read as enclosed, which would push guardians towards the
# middle of the map for a reason that has nothing to do with terrain.
func _openness_at(x: float, z: float, ground: float) -> float:
	var eye := ground + eye_height
	var ext_x: float = _terrain.world_extent_x()
	var ext_z: float = _terrain.world_extent_z()
	var total := 0.0

	for d in sight_directions:
		var angle := TAU * float(d) / float(sight_directions)
		var dir_x := cos(angle)
		var dir_z := sin(angle)
		var clear := sight_range

		for s in range(1, sight_steps + 1):
			var dist := sight_range * float(s) / float(sight_steps)
			var sx := x + dir_x * dist
			var sz := z + dir_z * dist
			if absf(sx) > ext_x or absf(sz) > ext_z:
				break
			if _terrain.surface_height(sx, sz) > eye:
				clear = dist
				break

		total += clear / sight_range

	return total / float(sight_directions)


# Percentile by RANK, not by interpolating between min and max. Rank is what
# makes "the top third of this valley" mean the same thing whatever shape the
# height distribution has - a field with one tall spike would otherwise put
# every other point in the bottom decile.
func _rank_elevation() -> void:
	var n := positions.size()
	elevation_percentile.resize(n)
	if n == 0:
		return

	var order: Array[int] = []
	order.resize(n)
	for i in n:
		order[i] = i

	var heights := positions
	order.sort_custom(func(a: int, b: int) -> bool: return heights[a].y < heights[b].y)

	var divisor := float(maxi(n - 1, 1))
	for rank in n:
		elevation_percentile[order[rank]] = float(rank) / divisor


## Quantiles of every metric across the candidate set.
##
## THIS IS HOW A PLACEMENT RULE GETS TUNED WITHOUT GUESSING. CLAUDE.md's rule is
## that a threshold goes between two MEASURED numbers; a rule written as
## "openness above 0.45" is a guess until someone has seen what openness this
## valley actually produces. It is logged on every load for exactly that reason,
## and it is the first thing to re-read when session C swaps the hills for a real
## DEM and every threshold in the manifest becomes suspect at once.
func metrics_summary() -> Dictionary:
	var heights := PackedFloat32Array()
	heights.resize(positions.size())
	for i in positions.size():
		heights[i] = positions[i].y

	return {
		"candidates": positions.size(),
		"slope_degrees": _quantiles(slope_degrees),
		"openness": _quantiles(openness),
		"height": _quantiles(heights),
	}


func _quantiles(values: PackedFloat32Array) -> Dictionary:
	if values.is_empty():
		return {}

	var sorted := values.duplicate()
	sorted.sort()
	var last := sorted.size() - 1

	return {
		"min": snappedf(sorted[0], 0.001),
		"p25": snappedf(sorted[int(last * 0.25)], 0.001),
		"p50": snappedf(sorted[int(last * 0.50)], 0.001),
		"p75": snappedf(sorted[int(last * 0.75)], 0.001),
		"max": snappedf(sorted[last], 0.001),
	}
