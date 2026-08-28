extends SDF
class_name SDFHeightmap

# The real ground of the level: a Digital Elevation Model of Glen Coe, sampled
# bilinearly into a height and then subtracted from p.y, so below the surface is
# NEGATIVE (solid) and above it POSITIVE (air). That sign convention is
# chunk.gd's - it sets a corner bit when the sample is < iso - and every SDF in
# this project has to match it. sample() is `p.y - surface_height(x, z)`, the
# same shape as SDFHills, deliberately: the two are interchangeable inside an
# SDFComposite stack, and SDFComposite's height-field arithmetic assumes it.
#
# It is a heightmap dressed as a distance field, exactly as SDFHills is, and for
# the same reason: the moment craters are subtracted from it (see TerrainField)
# the result stops being a heightmap and grows overhangs and holes. The
# heightmap is the starting shape, not the representation.
#
# ------------------------------------------------------------------
# ORIENTATION - STATED, NOT IMPLIED
# ------------------------------------------------------------------
# Row 0 of the raster is NORTH and column 0 is WEST (see the provenance sidecar
# terrain/heightmaps/valley-heightmap.json). Rows map to INCREASING z and
# columns to INCREASING x, so in this world:
#
#     -Z is NORTH   +Z is SOUTH   -X is WEST   +X is EAST
#
# i.e. -Z forward, Godot's usual convention. It is written down because nothing
# else in the project records it and nothing can recover it: the crop is square
# and a glen is roughly symmetric, so a flipped axis yields an entirely
# plausible valley that simply is not Glen Coe.
#
# ------------------------------------------------------------------
# NO ASPECT CORRECTION HAPPENS HERE
# ------------------------------------------------------------------
# The source .asc was 119 x 65 cells - square in DEGREES, and a degree of
# longitude is only ~61 km at 56.67 N - covering ground that is 2022 x 2010 m,
# i.e. very nearly square. dem_to_heightmap.py already resampled to 119 x 119
# isotropic pixels before writing the PNG. Correcting aspect again here would
# double-correct and stretch the glen the other way.
#
# ------------------------------------------------------------------
# THE PIXEL-TO-WORLD MAPPING
# ------------------------------------------------------------------
# Pixel CENTRES sit on the footprint's edges: column 0 at the west edge, column
# w-1 at the east edge. So the pixel pitch is world_size.x / (w - 1) - with the
# authored 192 m over 119 px that is 1.6271 world units, just under one voxel
# (voxel_size 2.0), which is why bilinear rather than nearest is not optional:
# at this scale nearest-neighbour terraces are a whole pixel wide and visible.
# Outside the footprint the edge value is extended, so a chunk grid larger than
# `world_size` gets flat ground rather than a wrapped or mirrored glen.

# ------------------------------------------------------------------
# Caches - DECLARED FIRST, AND THAT IS LOAD-BEARING
# ------------------------------------------------------------------
# Every @export below writes through to these from its setter, and a setter
# fires during construction as the member initialisers run. Declared after the
# exports these would still be null at that moment. The setters null-guard as
# well; both, because this is the trap SDFHills' `frequency` setter documents
# and the parent project shipped a heightmap SDF that ignored every tuned value
# in its own .tres while looking entirely correct.

# Normalised samples, 0..1, row-major, `_width` per row.
var _samples := PackedFloat32Array()
var _width: int = 0
var _height: int = 0

# Smallest and largest normalised sample actually present. vertical_extent()
# reads these rather than assuming the encoding's full 0..1 range is used.
var _norm_min: float = 0.0
var _norm_max: float = 1.0

# The affine parts of the mapping, folded once per edit so that the hot path is
# two multiply-adds rather than six. surface_height() runs ~227k times per chunk
# per rebuild (chunk.gd's `_sample_field`), so this is the same trade
# SDFComposite makes with its plan arrays.
var _u_scale: float = 0.0
var _u_bias: float = 0.0
var _v_scale: float = 0.0
var _v_bias: float = 0.0
var _height_gain: float = 0.0
var _height_bias: float = 0.0

# ------------------------------------------------------------------
# Measurement-facing state
# ------------------------------------------------------------------
# RECORDED ON THE CODE PATH THAT WRITES THEM, never mirrored per frame: a value
# copied each frame reports its pre-batch number to any harness eval that
# changed it, which reads as "nothing happened" about something that did (see
# main.gd's note on the same point).

## Image format enum measured off the loaded texture, or -1 when nothing loaded.
##
## THIS IS THE 16-BIT QUESTION, AS A NUMBER. Godot's texture importer is free to
## downconvert a 16-bit PNG, and the symptom - banding on smooth slopes - is
## invisible in every test in the sequence. Read it together with
## source_levels(), which measures the same thing from the data rather than from
## a declaration.
var source_format: int = -1

## True when the loaded image had to be decompressed before it could be read.
## A VRAM-compressed source is lossy in exactly the way a heightmap cannot
## afford; if this is ever true, fix the .import rather than the reader.
var source_was_compressed: bool = false

## Largest |grad surface_height| anywhere on the raster, in world units of
## height per world unit of x/z, at the CURRENT height_scale and world_size.
## Written by _rebuild_mapping(); `lipschitz` is derived from it.
var max_world_gradient: float = 0.0


## The raster this field is a picture of. Any Texture2D whose image can be read
## back on the CPU; the project's is terrain/heightmaps/valley-heightmap.png,
## imported lossless with mipmaps off and detect_3d disabled, so get_image()
## returns the pixels rather than a block-compressed approximation of them.
##
## Read through Color.r, so the format is not baked in: swapping the raster for
## an .exr or any float-format image needs no change here, only a different
## asset. See source_levels() for why that might one day be wanted.
##
## LEFT NULL THIS IS QUIET, NOT LOUD, and deliberately: the setter fires during
## construction with null before the loader assigns anything, so a push_error
## here would fire on every correct load. The signal that no raster arrived is
## source_size() reading (0, 0) and source_levels() reading 0.
@export var heightmap: Texture2D:
	set(value):
		heightmap = value
		_rebuild_samples()

## Real-world elevation, in metres, that a raw sample of 0 encodes.
## From terrain/heightmaps/valley-heightmap.json - keep the two in step.
@export var elevation_min_m: float = 64.0:
	set(value):
		elevation_min_m = value
		_rebuild_mapping()

## Real-world elevation span, in metres, across the raw sample range.
## elevation_m = elevation_min_m + (sample / 65535) * elevation_range_m.
@export var elevation_range_m: float = 877.0:
	set(value):
		elevation_range_m = value
		_rebuild_mapping()

## The real elevation, in metres, that lands at world y = 0.
##
## Held in METRES rather than folded into vertical_offset on purpose: the chunk
## grid is built around y = 0, and expressing the datum in real units means
## retuning height_scale re-centres the valley automatically instead of sliding
## it out of the meshed volume. Authored as the crop's MEAN elevation, so the
## typical ground sits on the grid's mid-plane.
@export var datum_elevation_m: float = 327.75:
	set(value):
		datum_elevation_m = value
		_rebuild_mapping()

## World units of height per real-world metre of elevation.
##
## THE ONE DIAL THAT DECIDES WHAT THIS VALLEY FEELS LIKE. The crop carries 877 m
## of real relief and the world is 192 world units across, so a 1:1 mapping is
## absurd; this compresses it. It cannot be reasoned out from the DEM alone -
## tune it against Terrain.surface_height_range() and Terrain.surface_clearance()
## and put the measured numbers in the commit, the way SDFHills.amplitude
## documents its own.
##
## THE DEFAULT DELIBERATELY IS NOT WHAT world_field.tres AUTHORS. 0.0194 is the
## scale that merely equalises TOTAL relief with the hills this replaced (877 m
## onto the old 17 m); the level authors 0.04, measured below. Keeping the two
## different is what makes a .tres that failed to resolve VISIBLE - see
## CLAUDE.md on a null-guarded fallback whose defaults match the authored file
## and so reproduces its numbers exactly.
##
## Measured over the whole 192 m footprint, at 0.04, with datum 327.75:
##   Terrain.surface_height_range(24) -> (-10.269, 23.653, 8.396)
##   Terrain.surface_clearance()      -> 24.347   (of a 96-unit-tall grid)
##   candidate-pool slope degrees     -> p25 5.246, p50 12.853, p75 17.434,
##                                       max 42.687, under the tank's
##                                       floor_max_angle of 0.9 rad = 51.57 deg
@export var height_scale: float = 0.0194:
	set(value):
		height_scale = value
		_rebuild_mapping()

## Shifts the whole surface up or down, in world units, after the datum has been
## applied. Normally 0 - move `datum_elevation_m` instead, which survives a
## height_scale change.
@export var vertical_offset: float = 0.0:
	set(value):
		vertical_offset = value
		_rebuild_mapping()

## World-space footprint the raster covers: x on the first component, z on the
## second, centred on `world_centre`.
##
## AUTHORED TO MATCH THE CHUNK GRID, and it is the one number here that can
## silently disagree with something else: Terrain's grid spans
## chunks_x * chunk_resolution * voxel_size (4 * 24 * 2 = 192) and this must
## equal it, or the glen is cropped or ringed by flat edge-extended ground.
## Nothing enforces the equality, so a resized grid means re-authoring this.
@export var world_size: Vector2 = Vector2(192.0, 192.0):
	set(value):
		world_size = value
		_rebuild_mapping()

## Where the raster's centre sits in world x/z. The chunk grid is centred on the
## origin, so this is 0,0 for the level as it stands.
@export var world_centre: Vector2 = Vector2.ZERO:
	set(value):
		world_centre = value
		_rebuild_mapping()


## Raster dimensions actually loaded, or (0, 0) when nothing was.
func source_size() -> Vector2i:
	return Vector2i(_width, _height)


## How many DISTINCT height levels the loaded raster actually carries.
##
## The independent half of the 16-bit question. `source_format` reports what
## Godot says the image is; this counts what came out of it, so an 8-bit
## downconvert shows up as a ceiling of 256 whatever the format enum claims.
##
## MEASURED, 2026-08: the PNG on disk holds 10226 distinct 16-bit values across
## its 14161 pixels, and this returns 256 - Godot's texture importer downconverts
## 16-bit greyscale PNG to FORMAT_L8 (source_format 0). The precision loss is
## real and it is currently sub-voxel: 877 m of relief over 255 steps is 3.44 m
## per step, which at height_scale 0.04 is 0.138 world units against a
## voxel_size of 2.0, so a terrace is at worst 0.138 / tan(slope) wide - 0.6
## units at the pool's median slope, well inside one voxel. Raise height_scale
## far enough, or drop voxel_size, and that stops being true; this is the number
## that says so, and an .exr raster is the fix if it ever does.
##
## Computed on read rather than cached: it is a measurement nobody asks for
## during play, and a cached copy is one more thing that can go stale.
func source_levels() -> int:
	var seen := {}
	for value in _samples:
		seen[value] = true
	return seen.size()


## Height of the surface at a world x/z, in world units, ignoring anything
## carved out of it afterwards. Implements SDF's height-field interface;
## Terrain.surface_height() reaches through this to decide where the tank spawns
## and the neon material's ramp reads vertical_extent() below.
##
## The bilinear filter is written out here rather than in a helper because this
## is the hot path - one call per voxel corner, ~227k per chunk per rebuild -
## and a nested call per sample is measurable at that count. chunk.gd inlines
## its buffer indexing for the same reason.
func surface_height(x: float, z: float) -> float:
	if _width < 2 or _height < 2:
		# No raster, or a degenerate one. Flat ground at whatever height a zero
		# sample encodes, quietly: a complaint belongs at load, in
		# _rebuild_samples(), not seven million times per build. The number that
		# says this happened is source_size() reading (0, 0).
		return _height_bias

	var u := clampf(x * _u_scale + _u_bias, 0.0, float(_width - 1))
	var v := clampf(z * _v_scale + _v_bias, 0.0, float(_height - 1))

	var x0 := int(u)
	var y0 := int(v)
	var x1 := mini(x0 + 1, _width - 1)
	var y1 := mini(y0 + 1, _height - 1)
	var fx := u - float(x0)
	var fy := v - float(y0)

	var row0 := y0 * _width
	var row1 := y1 * _width
	var top := _samples[row0 + x0] + (_samples[row0 + x1] - _samples[row0 + x0]) * fx
	var bottom := _samples[row1 + x0] + (_samples[row1 + x1] - _samples[row1 + x0]) * fx

	return (top + (bottom - top) * fy) * _height_gain + _height_bias


func sample(p: Vector3, _chunk_offset: Vector3 = Vector3.ZERO) -> float:
	return p.y - surface_height(p.x, p.z)


## Implements SDF's height-field interface: how far the surface reaches away
## from y = 0, which drives the terrain material's hue ramp.
##
## EXACT HERE, not a bound. SDFHills has to over-report because layered fBm does
## not saturate, but a raster's extremes are known - they are the smallest and
## largest sample in it - so this is the realised relief rather than a ceiling
## the surface never reaches.
func vertical_extent() -> float:
	var lo := _norm_min * _height_gain + _height_bias
	var hi := _norm_max * _height_gain + _height_bias
	return maxf(absf(lo), absf(hi))


# ------------------------------------------------------------------
# Rebuilds
# ------------------------------------------------------------------
# Called from the setters rather than from _init(), because _init() runs BEFORE
# the loader assigns exported values. Order-independent by construction: each
# rebuilds from the current state of every export, so whichever the loader
# assigns last still leaves the field correct. This is SDFComposite's
# _rebuild_plan() pattern, for the same reason.

func _rebuild_samples() -> void:
	_samples = PackedFloat32Array()
	_width = 0
	_height = 0
	_norm_min = 0.0
	_norm_max = 1.0
	source_format = -1
	source_was_compressed = false

	if heightmap == null:
		_rebuild_mapping()
		return

	var image := heightmap.get_image()
	if image == null:
		push_error("SDFHeightmap: '%s' has no readable image" % heightmap.resource_path)
		_rebuild_mapping()
		return

	source_format = image.get_format()

	if image.is_compressed():
		# Block compression is lossy in exactly the way a heightmap cannot
		# afford. Decompress so the read succeeds at all, and record it: the fix
		# is the texture's .import settings, not this branch.
		source_was_compressed = true
		if image.decompress() != OK:
			push_error("SDFHeightmap: '%s' is compressed (format %d) and will not decompress"
				% [heightmap.resource_path, source_format])
			_rebuild_mapping()
			return

	_width = image.get_width()
	_height = image.get_height()
	if _width < 2 or _height < 2:
		push_error("SDFHeightmap: '%s' is %dx%d - too small to interpolate"
			% [heightmap.resource_path, _width, _height])
		_width = 0
		_height = 0
		_rebuild_mapping()
		return

	_samples.resize(_width * _height)
	var lo := INF
	var hi := -INF
	var i := 0
	for y in _height:
		for x in _width:
			# Greyscale, so any channel does; red is the one every format has.
			var value := image.get_pixel(x, y).r
			_samples[i] = value
			lo = minf(lo, value)
			hi = maxf(hi, value)
			i += 1

	_norm_min = lo
	_norm_max = hi
	_rebuild_mapping()


func _rebuild_mapping() -> void:
	_height_gain = elevation_range_m * height_scale
	_height_bias = (elevation_min_m - datum_elevation_m) * height_scale + vertical_offset

	_u_scale = 0.0
	_u_bias = 0.0
	_v_scale = 0.0
	_v_bias = 0.0

	if _width >= 2 and world_size.x > 0.0:
		_u_scale = float(_width - 1) / world_size.x
		_u_bias = -(world_centre.x - world_size.x * 0.5) * _u_scale
	if _height >= 2 and world_size.y > 0.0:
		_v_scale = float(_height - 1) / world_size.y
		_v_bias = -(world_centre.y - world_size.y * 0.5) * _v_scale

	_update_lipschitz()


# The Lipschitz factor, DERIVED FROM THE DATA rather than guessed.
#
# sample() is `p.y - h(x, z)`, so its gradient is (-dh/dx, 1, -dh/dz) and its
# magnitude is sqrt(1 + |grad h|^2). |grad h| is bounded on a bilinear surface by
# the largest neighbouring-pixel difference, because between two pixel centres
# the interpolant is linear and its slope IS that difference over the pitch. So
# walking the raster once per edit gives the exact bound, and there is no number
# to guess.
#
# What consumes it: SDFComposite reports max(layer.lipschitz) for a hard union
# stack, and TerrainField multiplies that by CRATER_LIPSCHITZ. See SDF.lipschitz
# for what anything sphere-tracing this field owes it.
func _update_lipschitz() -> void:
	max_world_gradient = 0.0
	lipschitz = 1.0

	if _samples == null or _width < 2 or _height < 2:
		return
	if world_size.x <= 0.0 or world_size.y <= 0.0:
		return

	var pitch_x := world_size.x / float(_width - 1)
	var pitch_z := world_size.y / float(_height - 1)
	var gain := _height_gain
	var worst := 0.0

	for y in _height:
		var row := y * _width
		var next_row := row + _width
		for x in _width:
			var here := _samples[row + x]
			var gx := 0.0
			var gz := 0.0
			if x + 1 < _width:
				gx = (_samples[row + x + 1] - here) * gain / pitch_x
			if y + 1 < _height:
				gz = (_samples[next_row + x] - here) * gain / pitch_z
			worst = maxf(worst, sqrt(gx * gx + gz * gz))

	max_world_gradient = worst
	lipschitz = sqrt(1.0 + worst * worst)
