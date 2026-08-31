extends Node3D
class_name HealthBar3D

# A health bar that lives in the world, above the thing it describes.
#
# WHY THIS IS NOT THE HUD BAR. The player's bar is screen-space, always in the
# same corner, and describes the one entity the camera is attached to; this one
# has to be found, has to face a camera that moves, and has to say WHICH of six
# towers is nearly down. They share a number - Damageable.health_fraction() -
# and nothing else, so they are two widgets rather than one with a flag.
#
# IT FINDS ITS OWN DAMAGEABLE, through Damageable.of(get_parent()), which is the
# project's one definition of where that component sits relative to its entity.
# So dropping this node under anything killable is the whole of the wiring: no
# export to point at a sibling, no path to go stale when a scene is rearranged.
# That is what "reusable" has to mean for S4c to get it for free.
#
# DRIVEN BY THE `damaged` SIGNAL, NOT BY _process(). The bar changes exactly when
# health changes, which is a handful of times per run - polling it 60 times a
# second per tower would be the same picture at a cost. It is also what keeps
# `fill_width` honest inside a --harness-eval batch: no frame runs there, so a
# per-frame mirror would report its pre-batch width to anyone who had just shot
# the tower (main.gd:62, CLAUDE.md on the eval batch).
#
# MESHES BUILT IN CODE, following ExplosionDirector's reasoning: two quads and
# two materials authored as .tres are four more resources for test 2 to walk and
# four more things to go stale on a folder move, for a widget that is thirty
# lines of setup.
#
# THE FILL SHRINKS BY RESIZING ITS MESH, NOT BY SCALING ITS NODE. Both materials
# billboard, and a billboard replaces the model-view basis with the camera's -
# which discards the node's scale unless FLAG_BILLBOARD_KEEP_SCALE is set. A
# scaled node would therefore read back correctly from the harness and draw at
# full width on screen, which is the exact shape of wrong this project keeps
# meeting. Resizing the QuadMesh moves vertices in model space, which billboards
# fine, and `center_offset` re-anchors it to the left edge so the bar empties
# from the right rather than shrinking towards its middle.

## Width and height of the bar in world units, at full health.
@export var bar_width: float = 6.0
@export var bar_height: float = 0.7

## Fill colour at full health and at zero, lerped between. Colour carries the
## same information as the width for the same reason the reload bar's does: at
## the distance a tower is usually shot from, the width is a few pixels.
@export var full_color: Color = Color(0.15, 0.95, 0.45)
@export var empty_color: Color = Color(0.95, 0.2, 0.15)

## The plate the fill is drawn on, so an empty bar is still a bar rather than
## nothing.
@export var back_color: Color = Color(0.03, 0.03, 0.05, 0.85)

## Fraction of the bar currently filled - 1.0 untouched, 0.0 destroyed.
##
## WRITTEN ON THE CODE PATH THAT SETS IT, in _refresh(), never mirrored per
## frame. Read it together with `fill_width`, which is derived differently: this
## is the fraction that was written, that is the mesh's own size read back off
## the resource the write landed in.
var fill_fraction: float = 1.0

## Width of the fill mesh in world units. Read off the QuadMesh the write landed
## in rather than recomputed, so it is evidence about the geometry rather than a
## second evaluation of `fill_fraction`.
var fill_width: float:
	get:
		return _fill_mesh.size.x if _fill_mesh != null else 0.0

var _back: MeshInstance3D
var _fill: MeshInstance3D
var _fill_mesh: QuadMesh
var _damageable: Damageable


func _ready() -> void:
	_build()

	_damageable = Damageable.of(get_parent())
	if _damageable == null:
		# Loud rather than a bar frozen at full. A health bar over something with
		# no hit points is scenery that lies, and it lies in the direction that
		# looks fine.
		push_error("HealthBar3D on %s: parent has no Damageable to read"
			% ("null" if get_parent() == null else get_parent().name))
		return

	_damageable.damaged.connect(_on_damaged)
	_refresh()


## Vertical gap between the bottom of this bar and the highest point of the
## entity it hangs over.
##
## WHAT THIS IS FOR. A transform is a claim about intent until something measures
## the gap it left. Nothing in the test sequence asks where the bar ended up, and
## a bar sunk into the tower's cap renders, passes every check and is unreadable
## in play. Positive means the bar clears the geometry beneath it by that much;
## zero or below means it is inside it.
##
## Computed from live AABBs on read, so it cannot go stale and costs nothing when
## nobody asks. The bar's OWN meshes are excluded - measuring against itself
## would return the same number for every placement.
func clearance() -> float:
	var parent := get_parent()
	if parent == null:
		return INF

	var top := -INF
	for node in _geometry_below(parent):
		var aabb := node.global_transform * node.get_aabb()
		top = maxf(top, aabb.position.y + aabb.size.y)

	if top == -INF:
		return INF
	return (global_position.y - bar_height * 0.5) - top


# ------------------------------------------------------------
# Internals
# ------------------------------------------------------------
func _build() -> void:
	_back = MeshInstance3D.new()
	_back.name = "Back"
	var back_mesh := QuadMesh.new()
	back_mesh.size = Vector2(bar_width, bar_height)
	back_mesh.material = _bar_material(back_color)
	_back.mesh = back_mesh
	add_child(_back)

	_fill = MeshInstance3D.new()
	_fill.name = "Fill"
	# Toward the camera once billboarded, so the fill is never z-fighting the
	# plate it sits on.
	_fill.position = Vector3(0.0, 0.0, 0.02)
	_fill_mesh = QuadMesh.new()
	_fill_mesh.size = Vector2(bar_width, bar_height)
	_fill_mesh.material = _bar_material(full_color)
	_fill.mesh = _fill_mesh
	add_child(_fill)


# Unshaded and billboarded: this is a readout, not a surface, and it must not go
# dark when the tower it hangs over is between the player and the sun.
func _bar_material(colour: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.set_flag(BaseMaterial3D.FLAG_BILLBOARD_KEEP_SCALE, true)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = colour
	return mat


func _on_damaged(_amount: float, _source: Node3D) -> void:
	_refresh()


# The one place the bar is written. See the header for why the mesh is resized
# rather than the node scaled, and why center_offset is what keeps it anchored.
func _refresh() -> void:
	if _damageable == null or _fill_mesh == null:
		return

	fill_fraction = _damageable.health_fraction()

	var width := bar_width * fill_fraction
	_fill_mesh.size = Vector2(width, bar_height)
	# The fill's own centre moves left by half of what it lost, which puts its
	# left edge back where the plate's is.
	_fill_mesh.center_offset = Vector3(-(bar_width - width) * 0.5, 0.0, 0.0)

	var mat := _fill_mesh.material as StandardMaterial3D
	if mat != null:
		mat.albedo_color = empty_color.lerp(full_color, fill_fraction)


# Every GeometryInstance3D under `node` that is not part of this bar. Recursive,
# because a real model arrives as a nested scene rather than as one mesh - the
# same reason Tower._skin_geometry() recurses.
func _geometry_below(node: Node) -> Array[GeometryInstance3D]:
	var out: Array[GeometryInstance3D] = []
	for child in node.get_children():
		if child == self:
			continue
		if child is GeometryInstance3D:
			out.append(child)
		out.append_array(_geometry_below(child))
	return out
