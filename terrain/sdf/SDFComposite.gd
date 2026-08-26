extends SDF
class_name SDFComposite

# An ordered stack of SDFs folded together with SDFOps' combinators. Layer 0 is
# the base shape; every later layer is applied on top of the result so far with
# its own op and its own blend width, so a level's ground becomes
# `heightmap (+) fBm detail (+) authored primitives` instead of one hand-written
# sample() per archetype.
#
# WHY A STACK AND NOT AN EXPRESSION TREE. SDFOps' header explains that sample()
# runs ~227k times per chunk and rejects a tree of SDF nodes on exactly that
# ground. A flat ordered list is the cheapest structure that still composes: one
# virtual call per LAYER per voxel, not one per node of an expression. Keep the
# stack short and put the cheap layers first.
#
# WHAT THIS IS NOT. It is not where craters live. Carving stays in TerrainField,
# one level ABOVE the ground field, and that separation is the whole reason the
# ground can be swapped for a composite without touching destruction at all.
#
# SIGN CONVENTION, as everywhere else here: NEGATIVE is solid, positive is air.

## Which combinator folds a layer into the stack below it. Values are stable -
## they are written into .tres files as plain ints.
enum Op {
	UNION = 0,        ## min(): hard join. Preserves |grad| <= 1.
	SMOOTH_UNION = 1, ## Polynomial smooth min over `blend` world units.
	SUBTRACT = 2,     ## max(a, -b): removes the layer from the stack below it.
}

# Reported by lipschitz when the stack contains a smoothed op. Matches the
# factor TerrainField records for its smooth crater subtraction, and matches it
# DELIBERATELY: the two are the same op family and there is no reason for the
# same approximation to carry two different numbers in one project. Like that
# one it is a flat conservative allowance, not compounded per application -
# TerrainField applies op_smooth_subtract once per active crater and still
# records 2.0.
const SMOOTH_LIPSCHITZ := 2.0

# Returned by sample() when there is nothing in the stack. Large and positive,
# i.e. "air, a long way from anything": marching cubes then finds no sign change
# and emits no triangles, which is a visible empty world rather than a subtly
# wrong one. Finite rather than INF so no interpolation can produce NaN.
const EMPTY_DISTANCE := 1.0e9

## The stack, in application order. Element 0 is the base shape.
@export var layers: Array[SDF] = []:
	set(value):
		layers = value
		_rebuild_plan()

## Op per layer, as `Op` values, parallel to `layers`.
##
## SAME LENGTH AS `layers`, WITH INDEX 0 IGNORED. An offset-by-one scheme (ops
## for layers 1..n) reads tidier and is the classic way to get a stack like this
## silently wrong by one; keeping the arrays index-aligned makes a mismatch
## impossible to introduce by miscounting. Entries past the end default to
## UNION, so a stack authored with only `layers` set is a plain union stack -
## the safe default, and the one that preserves |grad| <= 1.
@export var layer_ops: Array[int] = []:
	set(value):
		layer_ops = value
		_rebuild_plan()

## Blend width per layer in world units, parallel to `layers`. 0 makes a
## smoothed op degrade to its hard version, which is what op_smooth_union does
## as k -> 0 anyway; this just skips the arithmetic.
@export var layer_blends: PackedFloat32Array = PackedFloat32Array():
	set(value):
		layer_blends = value
		_rebuild_plan()

# The validated, compacted stack that sample() actually walks: null entries
# dropped, ops and blends materialised to exactly one per surviving layer.
#
# Built once per edit rather than checked per voxel. sample() is the hot path
# and a bounds check plus a null check per layer per voxel is real cost for a
# question whose answer cannot change between rebuilds. Packed arrays for the
# same reason TerrainField uses them for craters: an untyped Array would box
# every op and blend into a Variant on read.
var _plan_layers: Array[SDF] = []
var _plan_ops := PackedInt32Array()
var _plan_blends := PackedFloat32Array()


## Layers actually folded by sample(). Read this rather than `layers.size()`.
##
## The two differ exactly when the stack holds a null entry - an empty slot left
## in the array, or a .tres whose sub-resource failed to resolve. That is a
## layer of the world silently not being there, which is the shape of wrong this
## project keeps paying for, so it gets a number of its own.
func layer_count() -> int:
	return _plan_layers.size()


## Layers configured, including any null ones. `layer_count()` minus this is the
## number of slots that are not contributing anything.
func configured_layer_count() -> int:
	return layers.size()


# Deliberately NOT forwarded to the layers, for the reason TerrainField's header
# gives: one field is shared by every chunk, so anything that mutated state here
# between chunks would make chunk 5 mesh a different world from chunk 4. Nothing
# currently overrides it; this override exists to make the silence intentional.
func on_generate() -> void:
	pass


func sample(p: Vector3, chunk_offset: Vector3 = Vector3.ZERO) -> float:
	var count := _plan_layers.size()
	if count == 0:
		return EMPTY_DISTANCE

	var d := _plan_layers[0].sample(p, chunk_offset)

	for i in range(1, count):
		var d_i := _plan_layers[i].sample(p, chunk_offset)
		var k := _plan_blends[i]

		match _plan_ops[i]:
			Op.SMOOTH_UNION:
				d = SDFOps.op_smooth_union(d, d_i, k) if k > 0.0 else SDFOps.op_union(d, d_i)
			Op.SUBTRACT:
				d = SDFOps.op_smooth_subtract(d, d_i, k) if k > 0.0 else SDFOps.op_subtract(d, d_i)
			_:
				d = SDFOps.op_union(d, d_i)

	return d


## Implements SDF's height-field interface, exactly - not as an approximation.
##
## For height fields, sample() is `y - h`, so `min(y - h1, y - h2)` is
## `y - max(h1, h2)`: a UNION in distance is a MAX in height. The smooth version
## follows the same way, and folding op_smooth_union over NEGATED heights
## reproduces it term for term (the polynomial is odd in that substitution), so
## there is no separate smooth_max to get subtly out of step with SDFOps.
##
## A SUBTRACT LAYER IS SKIPPED, AND THAT IS CORRECT RATHER THAN LAZY. Removing a
## solid from a height field does not leave a height field - it leaves overhangs
## and holes, which is precisely what makes destruction interesting. This
## function has always meant "the height of the ORIGINAL ground" (see
## SDFHills.surface_height, which ignores craters the same way and for the same
## reason). Anything that must not be placed inside a hole raycasts against the
## terrain's collision instead.
func surface_height(x: float, z: float) -> float:
	var count := _plan_layers.size()
	if count == 0:
		push_error("SDFComposite.surface_height(): stack is empty")
		return 0.0

	var h := _plan_layers[0].surface_height(x, z)

	for i in range(1, count):
		var op := _plan_ops[i]
		if op == Op.SUBTRACT:
			continue

		var h_i := _plan_layers[i].surface_height(x, z)
		var k := _plan_blends[i]

		if op == Op.SMOOTH_UNION and k > 0.0:
			h = -SDFOps.op_smooth_union(-h, -h_i, k)
		else:
			h = maxf(h, h_i)

	return h


## Implements SDF's height-field interface.
##
## Union takes the max in the height domain (see surface_height), so the stack
## reaches as high as its tallest layer - plus what each smoothed seam bulges
## over it. op_smooth_union(a, a, k) returns `a - k/4`, i.e. the joint crests a
## quarter of the blend width proud of both surfaces it joins, so every smoothed
## layer can add that much. Conservative on purpose: over-reporting makes the
## material's hue ramp span slightly more than the hills, and under-reporting
## clips the peak colour flat.
func vertical_extent() -> float:
	var widest := 0.0
	var bulge := 0.0

	for i in _plan_layers.size():
		widest = maxf(widest, _plan_layers[i].vertical_extent())
		if i > 0 and _plan_ops[i] == Op.SMOOTH_UNION:
			bulge += _plan_blends[i] * 0.25

	return widest + bulge


# Compacts the stack and recomputes everything derived from it. Called from all
# three setters rather than from _init(), because _init() runs BEFORE the loader
# assigns exported values - the trap SDFHills' `frequency` setter documents, and
# the reason the parent project shipped a field that ignored every tuned value
# in its own .tres while looking entirely correct.
#
# Order-independent by construction: each setter rebuilds from the current state
# of all three arrays, so whichever the loader happens to assign last leaves the
# plan correct. The null guards matter for the same reason - a setter fires
# during construction, when a member declared further down is still null.
func _rebuild_plan() -> void:
	_plan_layers = []
	_plan_ops = PackedInt32Array()
	_plan_blends = PackedFloat32Array()

	if layers == null:
		_update_lipschitz()
		return

	for i in layers.size():
		var layer: SDF = layers[i]
		if layer == null:
			continue
		_plan_layers.append(layer)
		_plan_ops.append(_configured_op(i))
		_plan_blends.append(_configured_blend(i))

	_update_lipschitz()


# Reads the whole stack's Lipschitz factor off its parts. See SDF.lipschitz for
# what the number is for, and SDFOps' header for which ops preserve |grad| <= 1.
#
# Two things combine. A layer that already over-reports distance keeps doing so
# through a hard combinator: min/max of two functions has the gradient of one of
# its operands almost everywhere, so union, intersect and hard subtract carry
# the WORST factor in the stack through unchanged - hence max(), not a product.
# A smoothed op is what actually breaks the bound, and it multiplies.
func _update_lipschitz() -> void:
	var worst := 1.0
	var smoothed := false

	for i in _plan_layers.size():
		worst = maxf(worst, _plan_layers[i].lipschitz)
		if i == 0:
			continue
		var op := _plan_ops[i]
		if (op == Op.SMOOTH_UNION or op == Op.SUBTRACT) and _plan_blends[i] > 0.0:
			smoothed = true

	lipschitz = worst * (SMOOTH_LIPSCHITZ if smoothed else 1.0)


func _configured_op(i: int) -> int:
	if layer_ops == null or i >= layer_ops.size():
		return Op.UNION
	return layer_ops[i]


func _configured_blend(i: int) -> float:
	if layer_blends == null or i >= layer_blends.size():
		return 0.0
	return layer_blends[i]
