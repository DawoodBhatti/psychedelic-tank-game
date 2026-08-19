extends Node3D
class_name Terrain

# The destructible world: a 3D grid of marching-cubes chunks, all meshing the
# same shared TerrainField, plus the one operation that makes the game a game -
# carve().
#
# The division of labour is worth stating once. TerrainField knows what the
# world is MADE OF and nothing about how it is cut up. TerrainChunk knows how
# to turn a field into triangles over one box and nothing about the world.
# Terrain owns the grid, and is therefore the only thing that can answer "which
# meshes changed when this crater appeared" - which is why carving lives here
# and not on the field, where it would read more naturally.

## Voxels along each axis of a chunk. Sampling cost is (this + 1) cubed PER
## CHUNK, so it is the single number that decides load time and rebuild hitch.
## Raise it for finer craters, and expect both to grow cubically.
@export var chunk_resolution: int = 24

## World units per voxel. With the default resolution a chunk spans 48 units.
## This also sets the finest detail a crater can have: a radius-8 crater is
## four voxels across at 2.0, which is chunky on purpose - the README asks for
## voxel-style destruction and this is what that looks like honestly.
@export var voxel_size: float = 2.0

@export var chunks_x: int = 4
@export var chunks_y: int = 2
@export var chunks_z: int = 4

## The shared field. Left null, a default hills field is built in _ready.
@export var field: TerrainField

## Material handed to every chunk. Shared deliberately - one material for the
## whole world means the neon look is retuned in one place.
@export var surface_material: Material

## Total chunks in the grid. Harness-facing.
var chunks_total: int = 0

## Triangles across every chunk. Harness-facing, and the quantity that proves a
## carve did something: it is derived from the meshes rather than from the
## carve code, so re-reading it is a check and not a re-execution.
var triangles_total: int = 0

## Craters carved since the last reset. Harness-facing, but NOT independent
## evidence - it is incremented by the carve itself. Use triangles_total or a
## chunk's mesh AABB to confirm material actually went.
var craters_carved: int = 0

## Chunks re-meshed by the most recent carve. If this is ever 0 on a hit that
## should have landed in the world, the crater missed the grid entirely.
var last_rebuild_count: int = 0

## Smallest distance from the last carve's centre to the edge of the grid.
## Negative means the shot landed outside the world, which is the failure this
## number exists to make visible - a carve outside the grid rebuilds nothing,
## costs nothing, and looks exactly like a carve that worked.
var last_carve_clearance: float = 0.0

var _chunks: Array[TerrainChunk] = []
var _extent: float = 0.0
var _world_min: Vector3 = Vector3.ZERO
var _world_max: Vector3 = Vector3.ZERO


func _ready() -> void:
	if field == null:
		field = TerrainField.new()
		field.ground = SDFHills.new()

	GameEvents.shell_exploded.connect(_on_shell_exploded)


## Builds every chunk. Synchronous and slow by design - the level is not
## playable until the collision exists, so there is nothing useful to do with a
## partially built world.
func build() -> void:
	var start_usec := Time.get_ticks_usec()

	_extent = chunk_resolution * voxel_size
	_world_min = Vector3(
		-chunks_x * _extent * 0.5,
		-chunks_y * _extent * 0.5,
		-chunks_z * _extent * 0.5)
	_world_max = _world_min + Vector3(chunks_x, chunks_y, chunks_z) * _extent

	for ix in chunks_x:
		for iy in chunks_y:
			for iz in chunks_z:
				var chunk := TerrainChunk.new()
				chunk.name = "Chunk_%d_%d_%d" % [ix, iy, iz]
				chunk.sdf = field
				chunk.surface_material = surface_material
				add_child(chunk)

				# generate() reads global_position, so the chunk has to be in
				# the tree and positioned before it runs.
				chunk.global_position = _world_min + Vector3(ix, iy, iz) * _extent

				var bounds := chunk.get_world_bounds()
				field.begin_chunk(bounds[0], bounds[1])
				chunk.generate(chunk_resolution, 0.0, voxel_size)

				_chunks.append(chunk)

	chunks_total = _chunks.size()
	_recount_triangles()

	var elapsed_ms := (Time.get_ticks_usec() - start_usec) / 1000.0
	GameLogger.write_log("state", "terrain_built", {
		"chunks": chunks_total,
		"triangles": triangles_total,
		"resolution": chunk_resolution,
		"voxel_size": voxel_size,
		"extent_per_chunk": _extent,
		"world_min": str(_world_min),
		"world_max": str(_world_max),
		"build_ms": snappedf(elapsed_ms, 0.1),
	})


## Blows a spherical hole at a world position and re-meshes only the chunks it
## reaches. Returns how many chunks were rebuilt.
##
## Cost is proportional to the number of chunks touched, not to the number of
## craters already carved - the field's begin_chunk() filter is what keeps that
## true, and active_crater_count() is how to check it still is.
func carve(centre: Vector3, radius: float) -> int:
	# Clearance BEFORE anything else: a shot outside the grid rebuilds nothing
	# and is indistinguishable from a successful one in every other reading.
	last_carve_clearance = _distance_inside_world(centre)

	field.add_crater(centre, radius)
	craters_carved += 1

	var reach: float = radius + field.crater_blend
	var hit_min := centre - Vector3.ONE * reach
	var hit_max := centre + Vector3.ONE * reach

	var rebuilt := 0
	for chunk in _chunks:
		var bounds := chunk.get_world_bounds()
		var box_min: Vector3 = bounds[0]
		var box_max: Vector3 = bounds[1]

		if hit_max.x < box_min.x or hit_min.x > box_max.x:
			continue
		if hit_max.y < box_min.y or hit_min.y > box_max.y:
			continue
		if hit_max.z < box_min.z or hit_min.z > box_max.z:
			continue

		field.begin_chunk(box_min, box_max)
		chunk.rebuild()
		rebuilt += 1

	last_rebuild_count = rebuilt
	_recount_triangles()

	GameEvents.terrain_carved.emit(centre, radius, rebuilt)
	return rebuilt


## Puts the world back to unbroken ground and re-meshes everything.
func reset() -> void:
	field.clear_craters()
	craters_carved = 0

	for chunk in _chunks:
		var bounds := chunk.get_world_bounds()
		field.begin_chunk(bounds[0], bounds[1])
		chunk.rebuild()

	last_rebuild_count = _chunks.size()
	_recount_triangles()


## Height of the original ground at a world x/z, ignoring craters. What to
## spawn things on.
func surface_height(x: float, z: float) -> float:
	return field.ground.surface_height(x, z)


## Relief of the ground across the whole world footprint, as
## (min height, max height, mean absolute height).
##
## Exists because "are the hills big enough to be worth driving over" is a
## question three sampled points cannot answer, and guessing it wrong is
## invisible: Perlin noise is exactly zero at every integer lattice point, so a
## sample that happens to land on one reports flat ground for terrain that is
## not. Walks a grid instead, and returns numbers a threshold can be put
## between.
func surface_height_range(samples_per_axis: int = 24) -> Vector3:
	var lo := INF
	var hi := -INF
	var total := 0.0

	var span_x := chunks_x * _extent
	var span_z := chunks_z * _extent
	var step_x := span_x / float(samples_per_axis)
	var step_z := span_z / float(samples_per_axis)

	for ix in samples_per_axis:
		var x := _world_min.x + (ix + 0.5) * step_x
		for iz in samples_per_axis:
			var z := _world_min.z + (iz + 0.5) * step_z
			var h := surface_height(x, z)
			lo = minf(lo, h)
			hi = maxf(hi, h)
			total += absf(h)

	var count := float(samples_per_axis * samples_per_axis)
	return Vector3(lo, hi, total / count)


## Half-width of the world on X, for anything that needs to stay inside it.
func world_extent_x() -> float:
	return chunks_x * _extent * 0.5


func world_extent_z() -> float:
	return chunks_z * _extent * 0.5


## Lowest y the grid covers. Anything below this has left the world.
func world_floor() -> float:
	return _world_min.y


func _on_shell_exploded(position: Vector3, radius: float) -> void:
	carve(position, radius)


func _recount_triangles() -> void:
	var total := 0
	for chunk in _chunks:
		total += chunk.triangle_count
	triangles_total = total


# Distance from `p` to the nearest face of the world box, positive inside and
# negative outside.
func _distance_inside_world(p: Vector3) -> float:
	var to_min := p - _world_min
	var to_max := _world_max - p
	return minf(
		minf(minf(to_min.x, to_min.y), to_min.z),
		minf(minf(to_max.x, to_max.y), to_max.z))
