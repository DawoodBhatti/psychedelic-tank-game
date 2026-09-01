extends Node3D
class_name SkinSlot

# The one node in an entity that is allowed to know what it looks like.
#
# WHY. The art has not been sourced yet, and when it arrives it must not be a
# rework. Every gameplay scene here holds its visuals inside a SkinSlot and
# never names a mesh anywhere else, so swapping a box for a downloaded hull is
# setting `skin_scene` on one resource - a data change, which is what the
# foundation plan promises session H will be.
#
# THE AUTHORED CHILDREN ARE THE PLACEHOLDER. Left with `skin_scene` null, this
# node does nothing at all and whatever the .tscn put under it stays. Set, the
# authored children are removed and the scene is instanced in their place. That
# ordering means a scene always looks like something: there is no state in which
# an entity is invisible because its skin was not assigned.
#
# THE EVIDENCE THAT A SWAP TOOK EFFECT IS THE REFERENCE, NOT THE PIXELS.
# `skin_source()` returns the resource path of whatever is actually mounted, so
# a swap can be confirmed headless, where no mesh is drawn at all.

## The visual to mount. Null keeps whatever the scene authored.
@export var skin_scene: PackedScene

## Forced onto EVERY GeometryInstance3D mounted here, at any depth. Null leaves
## each mesh with the material it shipped with, which is what every entity but
## the red tanks wants.
##
## RE-SKINNING AND RE-COLOURING ARE THE SAME QUESTION, WHICH IS WHY THIS LIVES
## HERE. "The enemy is our tank, entirely red" is not a second model - it is the
## same shape with one material on top - and this node is the only one in an
## entity allowed to know what it looks like. Setting it here rather than on the
## meshes means the red survives skin_scene being swapped for a sourced model:
## whatever arrives is painted on mount, with no second place to remember.
##
## NOT FOR ANYTHING THAT CARRIES PER-INSTANCE SHADER STATE. material_override
## replaces the surface material outright, so a tower - whose crack stage is an
## instance parameter written against its own ShaderMaterial - must leave this
## null, and does.
@export var material_override: Material

# Set only when skin_scene was applied; "" means the authored placeholder is
# still in place.
var _mounted_path: String = ""


func _ready() -> void:
	if skin_scene != null:
		set_skin(skin_scene)
	else:
		# The authored placeholder is staying, and it still has to be painted.
		# set_skin() does this itself, so this branch is only the other case.
		_apply_material_override()


## Replaces whatever is mounted with an instance of `scene`. Null clears the
## slot, which is a legitimate thing to want for an invisible trigger volume.
func set_skin(scene: PackedScene) -> void:
	# remove_child before queue_free, not queue_free alone: queue_free defers to
	# the end of the frame, so the old skin would still be a child - visible, and
	# counted - for the rest of it, and two skins would be mounted at once in
	# every screenshot taken in that frame.
	for child in get_children():
		remove_child(child)
		child.queue_free()

	skin_scene = scene
	_mounted_path = ""

	if scene == null:
		return

	add_child(scene.instantiate())
	_mounted_path = scene.resource_path
	_apply_material_override()


## Resource path of the mounted skin, or "" while the authored placeholder is
## still in place. The measurement that says which one an entity is wearing.
func skin_source() -> String:
	return _mounted_path


## Resource path of the override actually applied, or "" when there is none.
##
## THE EVIDENCE THAT A COLOUR ARRIVED IS THIS, NOT THE COLOUR. A null-guarded
## reference that fell back to a default-constructed material would report the
## same albedo as an authored .tres whose values match; only the path
## distinguishes them (CLAUDE.md, on moving a resource reference). Pair it with a
## region check on the pixels, which is evidence the material is being DRAWN.
func material_source() -> String:
	if material_override == null:
		return ""
	return material_override.resource_path


## Every GeometryInstance3D mounted under this slot, at any depth.
##
## Recursive because a real model arrives as a nested scene rather than as one
## mesh, and PUBLIC because two entities already need it - the tower writes its
## crack stage per instance, and the enemy is painted with the override above.
## One definition of "the geometry this slot is showing", for the same reason
## Damageable.of() is one definition of where hit points live.
func geometry() -> Array[GeometryInstance3D]:
	return _geometry_under(self)


# ------------------------------------------------------------
# Internals
# ------------------------------------------------------------
# Re-walked on every application rather than cached: set_skin() can replace the
# whole subtree at any time, and a cached list would hold freed nodes and
# silently stop painting anything - invisible, because writing to nothing raises
# nothing.
func _apply_material_override() -> void:
	if material_override == null:
		return
	for node in geometry():
		node.material_override = material_override


func _geometry_under(node: Node) -> Array[GeometryInstance3D]:
	var out: Array[GeometryInstance3D] = []
	for child in node.get_children():
		if child is GeometryInstance3D:
			out.append(child)
		out.append_array(_geometry_under(child))
	return out
