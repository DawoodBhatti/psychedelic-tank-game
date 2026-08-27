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

# Set only when skin_scene was applied; "" means the authored placeholder is
# still in place.
var _mounted_path: String = ""


func _ready() -> void:
	if skin_scene != null:
		set_skin(skin_scene)


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


## Resource path of the mounted skin, or "" while the authored placeholder is
## still in place. The measurement that says which one an entity is wearing.
func skin_source() -> String:
	return _mounted_path
