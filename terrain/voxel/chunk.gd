extends Node3D
class_name TerrainChunk

# One cubic block of marching-cubes terrain: samples a density field over a
# voxel grid, meshes the isosurface, and builds a collider from the same
# triangles.
#
# Ported from the parent project (flying-game-prototype / marching-cubes-
# prototype) with three changes, all of them forced by this game rather than
# preferences:
#
#   1. MESHING AND COLLIDER CREATION ARE SEPARATE. The original always did
#      add_child(StaticBody3D) at the end of meshing, which is correct exactly
#      once. Carving re-meshes a chunk that already exists, so calling that
#      twice stacked a second collider on top of the first - invisible in every
#      test in the sequence, and wrong in the way collision bugs are wrong.
#      generate() builds the nodes; rebuild() reuses them.
#
#   2. AN EMPTY CHUNK IS A NORMAL OUTCOME, NOT AN ERROR. A grid laid over hills
#      has chunks entirely above the surface and chunks entirely below it, and
#      both mesh to zero triangles. The original printed an error and called
#      add_surface_from_arrays anyway, which pushes a real engine error - and
#      an error in the log fails test 3. Empty chunks now return quietly.
#
#   3. It builds its own child nodes rather than requiring a scene with a
#      MeshInstance3D already in it, so Terrain can do TerrainChunk.new() in a
#      loop without a .tscn per chunk.
#
# No node-path lookups anywhere: a chunk must be usable wherever it is put.

# Lazy-loaded tables. Static so a world of N chunks does not hold N copies of
# the (large, immutable) lookup tables.
static var MC := preload("res://terrain/voxel/marching_cubes_tables.gd").new()

## Field to mesh. Shared with every other chunk in the world; see TerrainField.
@export var sdf: SDF

## Surface threshold. Corners sampling below this count as solid.
@export var iso_level: float = 0.0

## Material applied to the meshed surface. Shared, so do not set shader
## parameters on it per chunk - duplicate() first if a chunk ever needs its own.
@export var surface_material: Material

# Reusable scratch buffer for the twelve edge intersections of one cell.
var edge_vertex := PackedVector3Array()

# Output buffers, rebuilt on every mesh.
var vertices: PackedVector3Array = []
var normals: PackedVector3Array = []
var indices: PackedInt32Array = []

## Voxels along each axis. Sampling cost is (chunk_size + 1) cubed, so this is
## the single number that decides load time.
var chunk_size: int = 24

## World units per voxel. chunk_size * voxel_size is the chunk's world extent.
var voxel_size: float = 2.0

## Triangles in the current mesh. Read by the harness: it changes when material
## is removed, and it is derived differently from anything the carve code
## computes, so it is independent evidence that a crater did something.
var triangle_count: int = 0

var _mesh_instance: MeshInstance3D
var _static_body: StaticBody3D
var _collision_shape: CollisionShape3D


## First build. Creates the child nodes, so call it exactly once per chunk.
func generate(size: int, iso: float, voxel_size_: float) -> void:
	chunk_size = size
	iso_level = iso
	voxel_size = voxel_size_

	_ensure_nodes()
	rebuild()


## Re-samples and re-meshes in place, reusing the existing nodes. This is the
## one carving calls, and it is safe to call repeatedly.
func rebuild() -> void:
	if _mesh_instance == null:
		push_error("TerrainChunk.rebuild() before generate(); nothing to rebuild into.")
		return

	vertices.clear()
	normals.clear()
	indices.clear()
	edge_vertex.resize(12)

	# Kept from the original: an SDF may reseed itself here. TerrainField
	# deliberately does not - it is shared by every chunk and reseeding it
	# between chunks would mesh a different world per chunk, and move craters
	# already carved. The call stays so a different, per-chunk SDF still works.
	sdf.on_generate()

	var field := _sample_field(chunk_size, voxel_size)
	_march(field, chunk_size, iso_level)
	_build_mesh()
	_build_collision_shape()


## World-space AABB this chunk samples over, as [min_corner, max_corner]. The
## field's crater filter is driven off this, so it has to agree exactly with
## the loop bounds in _sample_field().
func get_world_bounds() -> Array:
	var origin: Vector3 = global_position
	var extent: Vector3 = Vector3.ONE * chunk_size * voxel_size
	return [origin, origin + extent]


## AABB of the meshed geometry, in world space, or an empty AABB for an empty
## chunk. Reads back non-empty headless on a procedural ArrayMesh, which is why
## it is the quantity to verify a carve against.
func get_mesh_aabb() -> AABB:
	if _mesh_instance == null or _mesh_instance.mesh == null:
		return AABB()
	var local := _mesh_instance.mesh.get_aabb()
	return AABB(global_position + local.position, local.size)


func _ensure_nodes() -> void:
	if _mesh_instance != null:
		return

	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.name = "MeshInstance3D"
	add_child(_mesh_instance)

	_static_body = StaticBody3D.new()
	_static_body.name = "StaticBody3D"
	# Layer 1 is terrain. The tank masks it to drive on it and shells mask it
	# to detonate against it; see CLAUDE.md's note on collision layers, which
	# are the thing here most likely to be silently wrong.
	_static_body.collision_layer = 1
	_static_body.collision_mask = 0
	add_child(_static_body)

	_collision_shape = CollisionShape3D.new()
	_collision_shape.name = "CollisionShape3D"
	_static_body.add_child(_collision_shape)


# ---------------------------------------------------------
# 1. Density sampling
# ---------------------------------------------------------
# Flat, typed buffer instead of a size^3 nested Array-of-Array-of-Array: avoids
# per-element Variant boxing, which dominates cost at larger chunk sizes.
func _sample_field(size: int, voxel: float) -> PackedFloat32Array:
	var dim := size + 1
	var field := PackedFloat32Array()
	field.resize(dim * dim * dim)

	var origin: Vector3 = global_position
	var offset: Vector3 = origin + Vector3.ONE * (size * voxel * 0.5)

	# Loops run z/y/x rather than x/y/z so the innermost loop walks the buffer
	# contiguously (the x term has stride 1), which also means the write index
	# is just a running counter. The per-sample index and dispatch calls are
	# inlined here: at tens of thousands of samples per chunk their overhead
	# alone is significant.
	var sdf_ref: SDF = sdf
	var ox := origin.x
	var i := 0

	for z in dim:
		var pz := origin.z + z * voxel
		for y in dim:
			var py := origin.y + y * voxel
			for x in dim:
				field[i] = sdf_ref.sample(Vector3(ox + x * voxel, py, pz), offset)
				i += 1

	return field


# Reference definition of the field buffer's memory layout. Inlined by hand in
# the sampling and marching loops; keep those in step with this if it changes.
func _field_index(x: int, y: int, z: int, dim: int) -> int:
	return x + y * dim + z * dim * dim


# ---------------------------------------------------------
# 2. Marching loop
# ---------------------------------------------------------
func _march(field: PackedFloat32Array, size: int, iso: float) -> void:
	var dim := size + 1

	# Hoisted out of the per-cell work: _march_cell runs size^3 times and both
	# of these were a function call on every one of them.
	var edge_table := MC.get_edge_table()
	var tri_table := MC.get_tri_table()

	for x in size:
		for y in size:
			for z in size:
				_march_cell(field, dim, x, y, z, iso, edge_table, tri_table)


# ---------------------------------------------------------
# 3. One cell
# ---------------------------------------------------------
func _march_cell(field: PackedFloat32Array, dim: int, x: int, y: int, z: int, iso: float,
		edge_table: PackedInt32Array, tri_table: Array) -> void:
	# Corner densities. Indices are derived from the cell's base offset by
	# adding the axis strides (1, dim, dim*dim) rather than calling
	# _field_index() eight times per cell.
	var dim2 := dim * dim
	var i0 := x + y * dim + z * dim2

	var d0 := field[i0]
	var d1 := field[i0 + 1]
	var d2 := field[i0 + 1 + dim]
	var d3 := field[i0 + dim]
	var d4 := field[i0 + dim2]
	var d5 := field[i0 + 1 + dim2]
	var d6 := field[i0 + 1 + dim + dim2]
	var d7 := field[i0 + dim + dim2]

	# NEGATIVE is inside. Every SDF in this project has to match this.
	var cube_index := 0
	if d0 < iso: cube_index |= 1
	if d1 < iso: cube_index |= 2
	if d2 < iso: cube_index |= 4
	if d3 < iso: cube_index |= 8
	if d4 < iso: cube_index |= 16
	if d5 < iso: cube_index |= 32
	if d6 < iso: cube_index |= 64
	if d7 < iso: cube_index |= 128

	var edge_mask := edge_table[cube_index]
	if edge_mask == 0:
		return

	# Corner positions in voxel-index space, scaled to local space by
	# voxel_size when the vertices are emitted below.
	var p0 := Vector3(x,   y,   z)
	var p1 := Vector3(x+1, y,   z)
	var p2 := Vector3(x+1, y+1, z)
	var p3 := Vector3(x,   y+1, z)
	var p4 := Vector3(x,   y,   z+1)
	var p5 := Vector3(x+1, y,   z+1)
	var p6 := Vector3(x+1, y+1, z+1)
	var p7 := Vector3(x,   y+1, z+1)

	if edge_mask & 1:    edge_vertex[0]  = _vertex_interp(p0, p1, d0, d1, iso)
	if edge_mask & 2:    edge_vertex[1]  = _vertex_interp(p1, p2, d1, d2, iso)
	if edge_mask & 4:    edge_vertex[2]  = _vertex_interp(p2, p3, d2, d3, iso)
	if edge_mask & 8:    edge_vertex[3]  = _vertex_interp(p3, p0, d3, d0, iso)
	if edge_mask & 16:   edge_vertex[4]  = _vertex_interp(p4, p5, d4, d5, iso)
	if edge_mask & 32:   edge_vertex[5]  = _vertex_interp(p5, p6, d5, d6, iso)
	if edge_mask & 64:   edge_vertex[6]  = _vertex_interp(p6, p7, d6, d7, iso)
	if edge_mask & 128:  edge_vertex[7]  = _vertex_interp(p7, p4, d7, d4, iso)
	if edge_mask & 256:  edge_vertex[8]  = _vertex_interp(p0, p4, d0, d4, iso)
	if edge_mask & 512:  edge_vertex[9]  = _vertex_interp(p1, p5, d1, d5, iso)
	if edge_mask & 1024: edge_vertex[10] = _vertex_interp(p2, p6, d2, d6, iso)
	if edge_mask & 2048: edge_vertex[11] = _vertex_interp(p3, p7, d3, d7, iso)

	# The field is sampled at origin + (x,y,z) * voxel_size but the marching
	# loop works in voxel indices, so vertices are scaled back up here; without
	# this any voxel_size other than 1.0 produces a mesh that does not match
	# the volume it was sampled from.
	var tri_row: Array = tri_table[cube_index]
	var i := 0
	while tri_row[i] != -1:
		var a: Vector3 = edge_vertex[tri_row[i]] * voxel_size
		var b: Vector3 = edge_vertex[tri_row[i + 1]] * voxel_size
		var c: Vector3 = edge_vertex[tri_row[i + 2]] * voxel_size

		var normal := ((b - a).cross(c - a)).normalized()

		var base := vertices.size()
		vertices.push_back(a)
		vertices.push_back(b)
		vertices.push_back(c)

		normals.push_back(normal)
		normals.push_back(normal)
		normals.push_back(normal)

		indices.push_back(base)
		indices.push_back(base + 1)
		indices.push_back(base + 2)

		i += 3


# ---------------------------------------------------------
# 4. Edge interpolation
# ---------------------------------------------------------
func _vertex_interp(p1: Vector3, p2: Vector3, v1: float, v2: float, iso: float) -> Vector3:
	if absf(iso - v1) < 0.00001:
		return p1
	if absf(iso - v2) < 0.00001:
		return p2
	if absf(v1 - v2) < 0.00001:
		return p1

	var t := (iso - v1) / (v2 - v1)
	return p1 + (p2 - p1) * t


# ---------------------------------------------------------
# 5. Mesh
# ---------------------------------------------------------
func _build_mesh() -> void:
	triangle_count = indices.size() / 3

	# A chunk entirely above the surface, or entirely inside it, meshes to
	# nothing. That is normal for a grid laid over hills, and it is normal
	# again after a crater removes a chunk's last solid corner. Calling
	# add_surface_from_arrays with empty arrays raises an engine error, and an
	# error in the log fails test 3, so bail before that rather than after.
	if vertices.is_empty():
		_mesh_instance.mesh = null
		return

	var mesh := ArrayMesh.new()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices

	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	_mesh_instance.mesh = mesh
	if surface_material != null:
		_mesh_instance.set_surface_override_material(0, surface_material)


# ---------------------------------------------------------
# 6. Collision
# ---------------------------------------------------------
# ConcavePolygonShape3D straight from the meshed triangles. Rebuilt rather than
# mutated: set_faces() on a shape a body is already using is the supported way
# to change it, and swapping the whole shape avoids depending on that.
func _build_collision_shape() -> void:
	if vertices.is_empty():
		_collision_shape.shape = null
		return

	var polygon := ConcavePolygonShape3D.new()
	polygon.set_faces(vertices)
	_collision_shape.shape = polygon
