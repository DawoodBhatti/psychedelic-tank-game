extends TerrainSurface
class_name HeightmapTerrain

# The big world: a geometry clipmap over a height field.
#
# Concentric square rings of flat grid mesh, centred on whatever node the level
# hands us. The innermost ring has base_spacing quads; each ring outward doubles
# the quad size and so covers four times the area. The meshes are built ONCE and
# never rebuilt - they slide with the player and a vertex shader displaces every
# vertex to its height. Cost is therefore fixed regardless of how wide the world
# is, which is the whole reason this exists: marching cubes meshes a VOLUME, so
# its cost is cubic in world width, and at 2000 units the same settings that
# built 384 units in 4.4 s would sample ~250 M voxels.
#
# It is also not paying a 3D price for 2D data. SDFHeightmap.sample() is
# `p.y - surface_height(x, z)` and has no overhangs by construction.
#
# ------------------------------------------------------------------
# ONE SOURCE OF TRUTH FOR HEIGHT, AND IT IS A NUMBER, NOT A FORMULA
# ------------------------------------------------------------------
# The vertex shader and the collider must produce the same surface or the tank
# drives on ground nobody can see. The obvious way to get that is to hand the
# shader SDFHeightmap's own constants - elevation_min_m, elevation_range_m,
# datum_elevation_m, height_scale, vertical_offset, world_size, world_centre -
# and re-implement the mapping in GLSL. This does something strictly stronger:
# it samples `field.ground.surface_height()` ONCE, on the CPU, into a float
# texture of world heights, and hands the shader the ANSWER.
#
# Three things that buys:
#   - there is no second copy of the arithmetic to drift, and no sRGB or
#     8-bit-downconvert question about how the shader reads the raster (see
#     SDFHeightmap.source_levels() for why that question is real here);
#   - the collider is built from the SAME PackedFloat32Array, so "visible ground
#     and collidable ground agree" is true by construction rather than by two
#     implementations happening to match;
#   - it works for ANY ground field - an SDFComposite stack, SDFHills, a future
#     fBm detail layer - because it only ever calls the height-field interface.
#
# The residual gap is that the texture is a RESAMPLING of the field at
# collision_pitch, so between texels the shader's bilinear is not exactly the
# field's bilinear. That gap is measured, not asserted:
# max_render_disagreement() below, and it is written into the terrain_built log
# entry on every load.
#
# ------------------------------------------------------------------
# HOW THE RINGS NEST WITHOUT A SEAM
# ------------------------------------------------------------------
# Each level snaps its own centre to twice its own quad size, so its vertices
# land on its own grid and never swim across the height field as the player
# drives. Level L's centre is floor(p / 2s) * 2s with s = base_spacing * 2^L;
# level L-1's is floor(p / s) * s. The difference is therefore EXACTLY 0 or s
# on each axis - never more, never negative - because floor(x/2)*2 and floor(x)
# differ by (x mod 2).
#
# So the hole level L must leave for level L-1 sits at one of FOUR positions on
# level L's quad grid. Rather than a trim strip, each ring level carries four
# pre-built meshes, one per hole position, and exactly one is visible. The hole
# then coincides with level L-1's footprint to the unit: no gap to fall through,
# no overlap to z-fight, and no mesh is ever rebuilt. Four variants cost mesh
# memory (~3 MB total) and nothing else - unreferenced vertices are not shaded.
#
# NOT IN SCOPE: geomorphing across ring boundaries. A naive clipmap pops when a
# ring changes level; whether that is visible at this speed and scale is a
# question for the eye, and it may not be. See docs/roadmap.md.
#
# ------------------------------------------------------------------
# KNOWN LIMITATION, STATED ONCE
# ------------------------------------------------------------------
# NASADEM is 1 arcsec - about 17 m east-west at this latitude. Mapped 1:1 that
# is one real sample every ~17 world units against a 4.2-unit tank, so the glen
# is correct at the scale of ridges and valleys and smooth at the scale of the
# vehicle. Size and detail are separate problems and a bigger crop only fixes
# size. Detail means procedural noise on top or a finer source; both deferred.

## Clipmap ring levels. Each doubles the quad size of the one inside it, so the
## world radius covered is grid_size * base_spacing * 2^(levels-1) / 2.
@export var levels: int = 6

## Quads along each side of a level's grid. MUST BE A MULTIPLE OF FOUR: the hole
## a ring leaves is grid_size/2 quads across and starts at quad grid_size/4.
@export var grid_size: int = 64

## World units per quad on the innermost ring. The tank is 4.2 units long, so
## this is the finest the ground is ever drawn.
@export var base_spacing: float = 2.0

## World-space footprint the COLLIDER and the height texture cover, centred on
## the origin. The clipmap itself reaches far beyond this; outside the footprint
## the shader clamps to the edge texel, which is exactly what
## SDFHeightmap.surface_height() does outside its raster, so the ground runs
## flat to the horizon rather than to void.
##
## IT MUST MATCH THE GROUND FIELD'S OWN FOOTPRINT and nothing enforces that.
## `SDFHeightmap.world_size` is authored in terrain/fields/world_field.tres and
## this is authored in main.tscn; a disagreement crops the glen or rings it with
## flat ground. The number that makes a mismatch visible is
## surface_height_range() - the relief collapses toward zero as the sampled box
## slides off the raster.
@export var world_size: Vector2 = Vector2(2022.0, 2010.0)

## World units between collider samples, and between height-texture texels - the
## two are the same grid, on purpose (see the header). 2.0 matches the voxel
## renderer's voxel_size and the innermost ring's quad size.
##
## HALVING IT QUADRUPLES BOTH THE LOAD COST AND THE TEXTURE. At 2.0 over this
## footprint that is ~1.02 M CPU height samples and a 4 MB R32F texture.
@export var collision_pitch: float = 2.0

## How far below the lowest ground world_floor() sits. The tank's death height
## is derived from it, so it only has to be clear of any terrain the tank can
## legitimately be under.
@export var floor_margin: float = 50.0

## Half-width of the central difference the vertex shader takes to build its
## normal, in world units. Deliberately equal to base_spacing AND to
## TerrainAnalysis.slope_step, so "slope" means the same thing to the contour
## fade, to the placement rules and to the eye.
##
## Fixed rather than per-ring on purpose: a normal derived from each ring's own
## quad size would change across a ring boundary and pop the shading there.
@export var normal_epsilon: float = 2.0

# `follow_target` is declared on TerrainSurface. Left null the clipmap sits at
# the origin, which is what a terrain-only test scene wants.

# ------------------------------------------------------------------
# The height grid - one array, three consumers
# ------------------------------------------------------------------
# Row-major, _map_w per row, index = j * _map_w + i, sample (i, j) at world
# (_map_origin.x + i * collision_pitch, _map_origin.y + j * collision_pitch).
# That is HeightMapShape3D's own layout AND Image's, which is why the collider
# and the render texture can be the same numbers rather than two passes.
var _heights := PackedFloat32Array()
var _map_w: int = 0
var _map_d: int = 0
var _map_origin := Vector2.ZERO

var _height_min: float = 0.0
var _height_max: float = 0.0

var _height_texture: ImageTexture
var _body: StaticBody3D

# One Node3D per level, each holding one MeshInstance3D child (level 0) or four
# hole-position variants (rings), of which exactly one is visible.
# _active_variant[L] is which. The variants are read back off the children
# rather than kept in a parallel array: two containers describing one tree is
# one container too many, and the tree is the one that cannot drift.
var _levels: Array[Node3D] = []
var _active_variant := PackedInt32Array()


func _ready() -> void:
	if field == null:
		field = TerrainField.new()
		field.ground = SDFHills.new()


func _process(_delta: float) -> void:
	if _levels.is_empty():
		return
	_update_centre()


# ------------------------------------------------------------------
# Build
# ------------------------------------------------------------------

func build() -> void:
	var start_usec := Time.get_ticks_usec()

	if field == null or field.ground == null:
		push_error("HeightmapTerrain.build(): no ground field - nothing to sample")
		return

	if _body != null:
		remove_child(_body)
		_body.queue_free()
		_body = null

	_sample_heights()
	_build_height_texture()
	_push_shader_uniforms()
	_build_collision()
	_build_meshes()
	_update_centre()

	var elapsed_ms := (Time.get_ticks_usec() - start_usec) / 1000.0
	GameLogger.write_log("state", "terrain_built", {
		"renderer": "clipmap",
		"chunks": chunk_count(),
		"triangles": triangle_count(),
		"levels": levels,
		"grid_size": grid_size,
		"base_spacing": base_spacing,
		"outer_extent": grid_size * base_spacing * pow(2.0, levels - 1),
		"collision_samples": _map_w * _map_d,
		"collision_pitch": collision_pitch,
		"height_min": snappedf(_height_min, 0.001),
		"height_max": snappedf(_height_max, 0.001),
		"render_disagreement": snappedf(max_render_disagreement(), 0.0001),
		"build_ms": snappedf(elapsed_ms, 0.1),
	})


## Nothing to put back: the clipmap cannot be changed at runtime. Kept as an
## explicit empty override rather than inherited, because "a reset does nothing
## here" is a statement about this terrain and not an omission.
func reset() -> void:
	pass


# One pass over the whole footprint, feeding both the collider and the render
# texture. ~1 M calls at the authored pitch, so it is the load-time cost that
# matters - and it is linear in area rather than cubic in width, which is the
# entire point of the change.
func _sample_heights() -> void:
	_map_w = _sample_count(world_size.x, collision_pitch)
	_map_d = _sample_count(world_size.y, collision_pitch)
	_map_origin = Vector2(
		-float(_map_w - 1) * collision_pitch * 0.5,
		-float(_map_d - 1) * collision_pitch * 0.5)

	_heights = PackedFloat32Array()
	_heights.resize(_map_w * _map_d)

	var ground: SDF = field.ground
	var pitch := collision_pitch
	var ox := _map_origin.x
	var lo := INF
	var hi := -INF
	var i := 0

	for j in _map_d:
		var z := _map_origin.y + j * pitch
		for k in _map_w:
			var h := ground.surface_height(ox + k * pitch, z)
			_heights[i] = h
			lo = minf(lo, h)
			hi = maxf(hi, h)
			i += 1

	_height_min = lo
	_height_max = hi


# Odd, so one sample lands exactly on the world origin - which makes
# surface_height(0, 0) a texel rather than an interpolation, and the tank's
# spawn point the one place the three representations cannot disagree.
func _sample_count(span: float, pitch: float) -> int:
	var n := int(ceil(span / pitch)) + 1
	if n % 2 == 0:
		n += 1
	return maxi(n, 2)


# R32F, so the texture holds WORLD HEIGHTS directly - signed, unquantised, and
# needing no mapping in the shader. An 8-bit or sRGB-tagged texture would put
# both a precision loss and a colour-space question between the CPU surface and
# the drawn one; this has neither.
func _build_height_texture() -> void:
	var image := Image.create_from_data(
		_map_w, _map_d, false, Image.FORMAT_RF, _heights.to_byte_array())
	_height_texture = ImageTexture.create_from_image(image)


func _push_shader_uniforms() -> void:
	var mat := surface_material as ShaderMaterial
	if mat == null:
		# Loud: without the height map every vertex stays at y = 0 and the world
		# is a flat plane, which renders and drives and looks like a bad DEM
		# rather than like a missing material.
		push_error("HeightmapTerrain: surface_material is not a ShaderMaterial - "
			+ "the clipmap will render flat at y = 0")
		return

	mat.set_shader_parameter("height_map", _height_texture)
	mat.set_shader_parameter("map_origin", _map_origin)
	mat.set_shader_parameter("map_step", Vector2(collision_pitch, collision_pitch))
	mat.set_shader_parameter("map_dim", Vector2i(_map_w, _map_d))
	mat.set_shader_parameter("normal_epsilon", normal_epsilon)


# HeightMapShape3D is a regular grid with UNIT spacing in shape space, so the
# body carries the pitch as scale. Uniform in x and z, 1.0 in y, so heights are
# not stretched.
func _build_collision() -> void:
	var shape := HeightMapShape3D.new()
	shape.map_width = _map_w
	shape.map_depth = _map_d
	shape.map_data = _heights

	_body = StaticBody3D.new()
	_body.name = "StaticBody3D"
	# Layer 1 is terrain. The tank masks it to drive on it and shells mask it to
	# detonate against it; see CLAUDE.md's note on collision layers, which are
	# the thing here most likely to be silently wrong. Measured off the live
	# body rather than read off this line - that is what the note asks for.
	_body.collision_layer = 1
	_body.collision_mask = 0
	add_child(_body)

	var collider := CollisionShape3D.new()
	collider.name = "CollisionShape3D"
	collider.shape = shape
	_body.add_child(collider)

	_body.scale = Vector3(collision_pitch, 1.0, collision_pitch)


func _build_meshes() -> void:
	# Idempotent, because a function that may only be called once and does not
	# say so is the shape of CLAUDE.md's generate()/rebuild() trap. A second
	# build() would otherwise stack a whole second clipmap on the first.
	for node in _levels:
		remove_child(node)
		node.queue_free()
	_levels.clear()
	_active_variant.resize(levels)

	var lo := _height_min - floor_margin
	var hi := _height_max + floor_margin

	for level in levels:
		var spacing := base_spacing * pow(2.0, level)
		var node := Node3D.new()
		node.name = "Level_%d" % level
		add_child(node)

		var half := grid_size * spacing * 0.5
		# WITHOUT THIS THE TERRAIN VANISHES AT ANY ANGLE. Every ring mesh is
		# flat on disk - the height only exists after the vertex shader has run -
		# so Godot's culling sees a zero-thickness slab at y = 0 and discards
		# rings whose displaced surface is plainly on screen.
		var bounds := AABB(Vector3(-half, lo, -half), Vector3(half * 2.0, hi - lo, half * 2.0))

		var variant_count := 1 if level == 0 else 4
		for v in variant_count:
			var mesh_instance := MeshInstance3D.new()
			mesh_instance.name = "Variant_%d" % v
			mesh_instance.mesh = _build_level_mesh(level, spacing, v)
			mesh_instance.custom_aabb = bounds
			mesh_instance.visible = (v == 0)
			if surface_material != null:
				mesh_instance.set_surface_override_material(0, surface_material)
			node.add_child(mesh_instance)

		_levels.append(node)
		_active_variant[level] = 0


# One level's grid, with the quads that level L-1 will cover left out. `variant`
# encodes the hole's position on this level's quad grid: bit 0 is the x parity,
# bit 1 the z parity (see the header for where those come from).
#
# Vertices for the hole are emitted and simply not indexed. An unreferenced
# vertex costs bytes and no shading, and keeping the vertex grid rectangular
# keeps the index arithmetic to one expression.
func _build_level_mesh(level: int, spacing: float, variant: int) -> ArrayMesh:
	var g := grid_size
	var stride := g + 1

	var hole_from := Vector2i(-1, -1)
	var hole_to := Vector2i(-1, -1)
	if level > 0:
		hole_from = Vector2i(g / 4 + (variant & 1), g / 4 + ((variant >> 1) & 1))
		hole_to = hole_from + Vector2i(g / 2, g / 2)

	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	vertices.resize(stride * stride)
	normals.resize(stride * stride)

	var half := g * spacing * 0.5
	var v := 0
	for j in stride:
		var z := -half + j * spacing
		for i in stride:
			vertices[v] = Vector3(-half + i * spacing, 0.0, z)
			# Overwritten in the vertex shader from the height texture. Present
			# so the mesh has a normal attribute at all.
			normals[v] = Vector3.UP
			v += 1

	var hole_w: int = maxi(hole_to.x - hole_from.x, 0)
	var hole_d: int = maxi(hole_to.y - hole_from.y, 0)
	var quads := g * g - hole_w * hole_d

	var indices := PackedInt32Array()
	indices.resize(quads * 6)
	var w := 0
	for j in g:
		var in_hole_z := j >= hole_from.y and j < hole_to.y
		for i in g:
			if in_hole_z and i >= hole_from.x and i < hole_to.x:
				continue
			# Godot's front faces are the winding whose (a-c) x (a-b) points out,
			# which for this order is +Y - i.e. visible from above. Getting it
			# backwards renders nothing at all, which is the failure test 6 is
			# for.
			var v00 := j * stride + i
			var v10 := v00 + 1
			var v01 := v00 + stride
			var v11 := v01 + 1
			indices[w] = v00
			indices[w + 1] = v10
			indices[w + 2] = v11
			indices[w + 3] = v00
			indices[w + 4] = v11
			indices[w + 5] = v01
			w += 6

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


# ------------------------------------------------------------------
# Sliding
# ------------------------------------------------------------------
# Positions only - never rotation, never scale. The vertex shader recovers the
# world position as VERTEX + MODEL_MATRIX[3].xyz, which is only the model
# transform when the model transform is a pure translation.
func _update_centre() -> void:
	var p := Vector2.ZERO
	if follow_target != null and is_instance_valid(follow_target):
		var origin := follow_target.global_position
		p = Vector2(origin.x, origin.z)

	for level in _levels.size():
		var spacing := base_spacing * pow(2.0, level)
		var node: Node3D = _levels[level]
		node.position = Vector3(
			_snap(p.x, spacing * 2.0), 0.0, _snap(p.y, spacing * 2.0))

		if level == 0:
			continue

		# The parity of floor(p / spacing) is exactly the offset between this
		# level's snapped centre and the next one in, in units of this level's
		# quad. See the header.
		var variant := posmod(int(floor(p.x / spacing)), 2) \
			| (posmod(int(floor(p.y / spacing)), 2) << 1)
		if variant == _active_variant[level]:
			continue

		for k in node.get_child_count():
			var mesh_instance := node.get_child(k) as MeshInstance3D
			mesh_instance.visible = k == variant
		_active_variant[level] = variant


func _snap(value: float, step: float) -> float:
	return floor(value / step) * step


# ------------------------------------------------------------------
# The TerrainSurface contract
# ------------------------------------------------------------------

func world_extent_x() -> float:
	return world_size.x * 0.5


func world_extent_z() -> float:
	return world_size.y * 0.5


## Below the lowest ground by floor_margin. There is no meshed volume here, so
## unlike the voxel grid this is not a box the surface has to fit inside - it is
## purely "the tank has fallen out of the world".
func world_floor() -> float:
	return _height_min - floor_margin


## Triangles in the rings that are actually visible, read off the meshes rather
## than counted while building them.
##
## get_child() rather than get_children(): the HUD asks for this every frame and
## get_children() allocates an Array each time it is called.
func triangle_count() -> int:
	var total := 0
	for node in _levels:
		for k in node.get_child_count():
			var mesh_instance := node.get_child(k) as MeshInstance3D
			if mesh_instance == null or not mesh_instance.visible:
				continue
			var mesh := mesh_instance.mesh as ArrayMesh
			if mesh == null or mesh.get_surface_count() == 0:
				continue
			total += mesh.surface_get_array_index_len(0) / 3
	return total


func chunk_count() -> int:
	return _levels.size()


## Worst distance, in world units, between the hole a ring leaves and the
## footprint of the ring that is supposed to fill it. 0.0 means every level
## nests exactly.
##
## THE CLEARANCE FOR THIS GENERATOR, and the one thing here that nothing else
## can see. Every ring's hole and the block inside it are the same size by
## construction, so the whole question is whether their CENTRES coincide - and
## that is decided each frame by snapping arithmetic and a choice of which of
## four pre-built meshes to show. Get it wrong and the result is either a strip
## of missing world the tank can see through, or two rings drawing the same
## ground at different tessellations and z-fighting over it. Neither raises an
## error, neither moves the triangle count, and neither shows up in any of the
## six tests.
##
## Read off the LIVE node positions and the LIVE visible-variant index, after
## the sliding code has run, so it checks that code rather than restating it.
## Drive the follow target somewhere and read it again: a value that is only
## ever 0 at the origin is a different claim from one that is 0 everywhere.
func ring_seam_mismatch() -> float:
	var worst := 0.0
	for level in range(1, _levels.size()):
		var spacing := base_spacing * pow(2.0, level)
		var outer: Node3D = _levels[level]
		var inner: Node3D = _levels[level - 1]
		var variant := _active_variant[level]

		# The hole spans quads [G/4 + parity, G/4 + parity + G/2) of this level,
		# so its centre sits `parity` quads off this level's own centre - and
		# its half-extent, G * spacing / 4, is exactly the inner level's.
		var hole_centre := Vector2(outer.position.x, outer.position.z) \
			+ Vector2(float(variant & 1), float((variant >> 1) & 1)) * spacing
		worst = maxf(worst, absf(hole_centre.x - inner.position.x))
		worst = maxf(worst, absf(hole_centre.y - inner.position.z))
	return worst


# ------------------------------------------------------------------
# Measurement-facing state - all computed on read
# ------------------------------------------------------------------
# WHAT THESE ARE FOR. This node decides where the world's mass lands and no test
# in the sequence asks where anything is. A clipmap is worse than most: the
# meshes on disk are FLAT, so mesh.get_aabb() describes a slab at y = 0 whatever
# the ground is doing, and headless compiles no shaders so the displacement
# never runs at all. Every number below is therefore computed from the live
# field, the live physics space or the live height grid at the moment it is
# asked - none is mirrored per frame, so none can report a pre-batch value.

## Worst vertical disagreement, in world units, between the ground the PHYSICS
## SERVER reports and the ground `field.ground.surface_height()` describes -
## measured by dropping `samples_per_axis` squared rays down the world.
##
## THIS IS THE ONE THAT MATTERS. The collider is built from a resampling of the
## field, and the visible surface from the same numbers, so an error here means
## the tank drives on ground nobody can see. It is independent evidence: a
## raycast asks Jolt where the triangles ended up, which is a different question
## from what this file put in the array - it covers the shape's scaling, its row
## order and its centring, none of which the array knows about.
##
## INF, not 0.0, when any ray misses. A ray that finds no collider at all is the
## catastrophic case and must not read as perfect agreement; INF fails any
## threshold put on this. Default 5 gives 25 rays.
func max_collision_disagreement(samples_per_axis: int = 5) -> float:
	var space := get_world_3d().direct_space_state
	if space == null:
		return INF

	var ext_x := world_extent_x()
	var ext_z := world_extent_z()
	var step_x := ext_x * 2.0 / float(samples_per_axis)
	var step_z := ext_z * 2.0 / float(samples_per_axis)
	var worst := 0.0

	for i in samples_per_axis:
		var x := -ext_x + (i + 0.5) * step_x
		for j in samples_per_axis:
			var z := -ext_z + (j + 0.5) * step_z
			var query := PhysicsRayQueryParameters3D.create(
				Vector3(x, _height_max + 100.0, z),
				Vector3(x, _height_min - 100.0, z))
			# Terrain only. A ray that stopped on the tank would report a
			# disagreement of several units about ground that is fine.
			query.collision_mask = 1
			var hit := space.intersect_ray(query)
			if hit.is_empty():
				return INF
			var ground: float = hit["position"].y
			worst = maxf(worst, absf(ground - surface_height(x, z)))

	return worst


## Worst vertical disagreement, in world units, between the height the VERTEX
## SHADER will compute and `field.ground.surface_height()` at the same x/z.
##
## The leg a raycast cannot reach. It is the cost of resampling the field into a
## texture at collision_pitch: at a texel centre the two are the same number by
## construction, and between texels the shader interpolates over
## collision_pitch-sized cells while the field interpolates over its raster's.
## Mirrors the shader's arithmetic exactly (see _texture_height).
func max_render_disagreement(samples_per_axis: int = 24) -> float:
	if _map_w < 2 or _map_d < 2:
		return INF

	var ext_x := world_extent_x()
	var ext_z := world_extent_z()
	var step_x := ext_x * 2.0 / float(samples_per_axis)
	var step_z := ext_z * 2.0 / float(samples_per_axis)
	var worst := 0.0

	for i in samples_per_axis:
		var x := -ext_x + (i + 0.5) * step_x
		for j in samples_per_axis:
			var z := -ext_z + (j + 0.5) * step_z
			worst = maxf(worst, absf(_texture_height(x, z) - surface_height(x, z)))

	return worst


## `1 - |n.y|` at a world x/z, computed exactly the way the vertex shader builds
## its normal: a central difference of the height texture at normal_epsilon.
##
## THIS IS THE QUANTITY THE CONTOUR RELIEF FADE IS CALIBRATED AGAINST. The
## shader kills contour lines on flat ground - see neon_terrain's
## CONTOUR_RELIEF_MIN - and those two constants have to sit between the measured
## flat and sloped populations of this number. Under the voxel renderer they
## were calibrated against FLAT-per-triangle marching-cubes normals, where the
## valley floor measured exactly 0.0000; a displaced grid produces continuous
## normals and the populations are a different shape, so they are re-derived
## rather than inherited.
func surface_relief(x: float, z: float) -> float:
	var e := normal_epsilon
	var gx := (_texture_height(x + e, z) - _texture_height(x - e, z)) / (2.0 * e)
	var gz := (_texture_height(x, z + e) - _texture_height(x, z - e)) / (2.0 * e)
	return 1.0 - 1.0 / sqrt(1.0 + gx * gx + gz * gz)


## Quantiles of surface_relief() over a grid across the footprint, as
## {min, p25, p50, p75, max}. The two populations a threshold goes between,
## measured rather than picked - the same job TerrainAnalysis.metrics_summary()
## does for placement rules.
func surface_relief_quantiles(samples_per_axis: int = 40) -> Dictionary:
	var values := PackedFloat32Array()
	values.resize(samples_per_axis * samples_per_axis)

	var ext_x := world_extent_x()
	var ext_z := world_extent_z()
	var step_x := ext_x * 2.0 / float(samples_per_axis)
	var step_z := ext_z * 2.0 / float(samples_per_axis)
	var n := 0

	for i in samples_per_axis:
		var x := -ext_x + (i + 0.5) * step_x
		for j in samples_per_axis:
			var z := -ext_z + (j + 0.5) * step_z
			values[n] = surface_relief(x, z)
			n += 1

	values.sort()
	var last := values.size() - 1
	return {
		"min": snappedf(values[0], 0.00001),
		"p25": snappedf(values[int(last * 0.25)], 0.00001),
		"p50": snappedf(values[int(last * 0.50)], 0.00001),
		"p75": snappedf(values[int(last * 0.75)], 0.00001),
		"max": snappedf(values[last], 0.00001),
	}


## Relief of the ground across the footprint, as (min, max, mean absolute
## height). Same signature and meaning as Terrain.surface_height_range(), so the
## two renderers' worlds are directly comparable.
func surface_height_range(samples_per_axis: int = 24) -> Vector3:
	var ext_x := world_extent_x()
	var ext_z := world_extent_z()
	var step_x := ext_x * 2.0 / float(samples_per_axis)
	var step_z := ext_z * 2.0 / float(samples_per_axis)

	var lo := INF
	var hi := -INF
	var total := 0.0

	for i in samples_per_axis:
		var x := -ext_x + (i + 0.5) * step_x
		for j in samples_per_axis:
			var z := -ext_z + (j + 0.5) * step_z
			var h := surface_height(x, z)
			lo = minf(lo, h)
			hi = maxf(hi, h)
			total += absf(h)

	return Vector3(lo, hi, total / float(samples_per_axis * samples_per_axis))


## Samples in the shared height grid, as (width, depth). (0, 0) before build().
func collision_grid_size() -> Vector2i:
	return Vector2i(_map_w, _map_d)


# The CPU mirror of the vertex shader's map_height(): manual bilinear over the
# height grid with the edges extended, which is what SDFHeightmap.surface_height()
# does over its raster and what the GLSL in heightmap_terrain.gdshader does over
# this texture. Three implementations of one interpolation is two too many; the
# alternative was a third arithmetic path in GLSL for the mapping itself, and
# max_render_disagreement() is what keeps this one honest.
func _texture_height(x: float, z: float) -> float:
	if _map_w < 2 or _map_d < 2:
		return 0.0

	var u := clampf((x - _map_origin.x) / collision_pitch, 0.0, float(_map_w - 1))
	var v := clampf((z - _map_origin.y) / collision_pitch, 0.0, float(_map_d - 1))

	var x0 := int(u)
	var z0 := int(v)
	var x1 := mini(x0 + 1, _map_w - 1)
	var z1 := mini(z0 + 1, _map_d - 1)
	var fx := u - float(x0)
	var fz := v - float(z0)

	var row0 := z0 * _map_w
	var row1 := z1 * _map_w
	var top := _heights[row0 + x0] + (_heights[row0 + x1] - _heights[row0 + x0]) * fx
	var bottom := _heights[row1 + x0] + (_heights[row1 + x1] - _heights[row1 + x0]) * fx
	return top + (bottom - top) * fz
