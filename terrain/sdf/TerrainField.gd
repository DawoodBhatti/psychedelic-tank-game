extends SDF
class_name TerrainField

# The world's one and only density field: ground hills, minus every crater a
# shell has blown in them.
#
# ONE FIELD, SHARED BY EVERY CHUNK. This is the opposite of the parent
# project's arrangement, where each chunk owned a duplicated SDF describing its
# own independent archetype, and it is not a style choice. A crater near a
# chunk boundary has to be seen identically by both chunks that straddle it, or
# the two meshes disagree and leave a seam through the middle of the hole. The
# only way to guarantee that is for both to be asking the same object.
#
# The consequence: on_generate() must NOT reseed or rebuild anything. In the
# parent it did, and chunk.gd still calls it - see the comment there. Reseeding
# a shared field between chunks would mean chunk 5 meshes a different world
# from chunk 4, and, worse, the craters carved so far would move.

## The ground surface before anything is blown out of it.
@export var ground: SDFHills

## Softness of a crater's rim, in world units. 0 gives a hard-edged spherical
## bite; a couple of units gives a melted lip that reads better under the neon
## material and hides the voxel stepping. Costs one extra lerp per crater per
## sample.
@export var crater_blend: float = 2.0

## Every crater ever carved, as parallel arrays. Parallel packed arrays rather
## than an Array of dictionaries or a Vector4: sample() reads these hundreds of
## thousands of times per chunk rebuild, and a packed array of floats avoids
## the per-element Variant boxing an untyped Array would cost.
var _crater_pos := PackedVector3Array()
var _crater_radius := PackedFloat32Array()

# The subset of the above that can possibly affect the chunk currently being
# sampled, rebuilt by begin_chunk(). Without this, sample() would walk every
# crater in the world on every voxel of every rebuild, so the cost of carving
# would grow with the number of craters already carved - the wrong direction
# for a mechanic whose whole point is doing it repeatedly.
var _active_pos := PackedVector3Array()
var _active_radius := PackedFloat32Array()


func _init() -> void:
	# Smooth subtraction does not preserve |grad| <= 1, so anything sphere
	# tracing this field must divide a sampled distance before treating it as a
	# safe step. Nothing does yet; the number is recorded so it is not
	# discovered the hard way later. See SDF.lipschitz and SDFOps' header.
	lipschitz = 2.0


# Deliberately empty. See the header: chunk.gd calls this before sampling, and
# a shared field must be identical for every chunk that calls it.
func on_generate() -> void:
	pass


## Number of craters in the world. Cheap, and the value a reset checks.
func crater_count() -> int:
	return _crater_pos.size()


## Craters that overlap the chunk currently being sampled. Exposed because it
## is the one number that says whether begin_chunk() is actually narrowing
## anything - if it equals crater_count() on a small chunk, the filter is not
## working and rebuild cost is about to grow without bound.
func active_crater_count() -> int:
	return _active_pos.size()


## Records a crater. Does NOT re-mesh anything - Terrain.carve() owns that,
## because deciding which chunks changed needs the chunk grid this field knows
## nothing about.
func add_crater(centre: Vector3, radius: float) -> void:
	_crater_pos.push_back(centre)
	_crater_radius.push_back(radius)


## Puts the world back to unbroken ground. Used by a level reset.
func clear_craters() -> void:
	_crater_pos.clear()
	_crater_radius.clear()
	_active_pos.clear()
	_active_radius.clear()


## Narrows the crater set to those that can reach the given world-space box,
## and returns how many survived. Call it immediately before asking a chunk
## covering that box to mesh itself.
##
## The box is expanded by each crater's own radius plus the blend width, so a
## crater whose centre sits outside the chunk but whose bite reaches inside is
## still included. Getting that expansion wrong is invisible in the middle of a
## chunk and shows up only as a step in the surface at the boundary.
func begin_chunk(box_min: Vector3, box_max: Vector3) -> int:
	_active_pos.clear()
	_active_radius.clear()

	for i in _crater_pos.size():
		var centre := _crater_pos[i]
		var reach: float = _crater_radius[i] + crater_blend
		if centre.x + reach < box_min.x or centre.x - reach > box_max.x:
			continue
		if centre.y + reach < box_min.y or centre.y - reach > box_max.y:
			continue
		if centre.z + reach < box_min.z or centre.z - reach > box_max.z:
			continue
		_active_pos.push_back(centre)
		_active_radius.push_back(_crater_radius[i])

	return _active_pos.size()


func sample(p: Vector3, chunk_offset: Vector3 = Vector3.ZERO) -> float:
	var d := ground.sample(p, chunk_offset)

	# Hoisted out of the loop: this runs per voxel, and `_active_pos.size()`
	# plus a property read on `crater_blend` on every iteration was measurable
	# against a body this small.
	var count := _active_pos.size()
	if count == 0:
		return d

	var k := crater_blend

	for i in count:
		var sphere := (p - _active_pos[i]).length() - _active_radius[i]
		# op_subtract removes the sphere from the ground: max(ground, -sphere).
		# Inside the sphere, -sphere is positive, so the result is positive,
		# which is air. That is the hole.
		if k > 0.0:
			d = SDFOps.op_smooth_subtract(d, sphere, k)
		else:
			d = SDFOps.op_subtract(d, sphere)

	return d
