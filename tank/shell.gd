extends Node3D
class_name Shell

# A fired shell. Ballistic, and swept by an explicit raycast rather than
# simulated as a RigidBody3D.
#
# WHY A RAYCAST AND NOT A BODY. At the tank's muzzle velocity a shell covers
# ~1.6 m per physics tick, and the terrain's thinnest features - a crater lip,
# a chunk of ground left standing between two hits - are thinner than that. A
# discrete body samples its position once per tick and passes clean through
# anything narrower, so shells silently vanish into hillsides. Godot's
# continuous CD would solve it for a body, at the cost of one, and this is
# cheaper and easier to reason about: cast from where the shell was to where it
# is about to be, and it cannot skip anything in between.
#
# It also makes the impact POINT exact, which matters here more than usual -
# that point is the centre of the crater, so a hit registered a metre late
# carves a hole a metre off from where the player saw the flash.

## Blast radius handed to the terrain. This is what "how big a hole" means.
@export var blast_radius: float = 8.0

## Seconds before an unhit shell gives up. A shell fired at the sky must not
## live for ever.
@export var lifetime: float = 12.0

@export var gravity: float = -22.0

## Layers the shell can hit. Deliberately does NOT include the tank's layer: a
## shell that masked its own firer would detonate on the barrel it left.
##
## TERRAIN ONLY, AND ENEMIES ARE MISSING ON PURPOSE. The foundation plan's mask
## table gives this row terrain AND enemies, and that is session E's change, not
## this one. Adding the bit now would make a shell detonate against a guardian
## and take zero hit points off it - a hit that visibly connects and does
## nothing, which is the exact failure DamageProfile.min_damage_fraction exists
## to prevent one layer up. Passing straight through is the more honest
## intermediate state: it is obviously unfinished rather than subtly broken.
##
## Not stored in shell.tscn - this default is the only place the value lives.
@export_flags_3d_physics var hit_mask: int = CollisionLayers.TERRAIN

var velocity: Vector3 = Vector3.ZERO

var _age: float = 0.0
var _launched: bool = false


## Sets the shell moving. Separate from _ready() because the position and the
## direction both come from the muzzle, and neither is known until the tank has
## parented it.
func launch(initial_velocity: Vector3) -> void:
	velocity = initial_velocity
	_launched = true
	_face_travel()


func _physics_process(delta: float) -> void:
	if not _launched:
		return

	_age += delta
	if _age > lifetime:
		queue_free()
		return

	velocity.y += gravity * delta

	var from := global_position
	var to := from + velocity * delta

	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = hit_mask
	# The shell has no body of its own, so there is nothing to exclude - but
	# stating it makes the intent survive anyone adding one later.
	query.exclude = []

	var hit := space.intersect_ray(query)

	if hit.is_empty():
		global_position = to
		_face_travel()
		return

	_detonate(hit["position"], hit.get("normal", Vector3.UP))


func _detonate(at: Vector3, normal: Vector3) -> void:
	# Pull the crater centre slightly INTO the surface along its normal.
	# Detonating exactly on the surface removes a hemisphere and leaves a
	# shallow scrape; sinking it by a third of the radius gives a hole that
	# reads as a hole. Anything deeper starts tunnelling under the ground and
	# leaving a thin crust the tank falls through.
	var centre := at - normal * (blast_radius * 0.33)

	GameEvents.shell_exploded.emit(centre, blast_radius)
	queue_free()


# Points the shell along its own velocity, so a long mesh reads as a
# projectile rather than a drifting brick.
func _face_travel() -> void:
	if velocity.length_squared() < 0.001:
		return
	var forward := velocity.normalized()
	# look_at fails when the direction is parallel to the up vector, which a
	# shell fired straight up is. Pick a different up in that case rather than
	# letting it push an error every frame of the flight.
	var up := Vector3.UP if absf(forward.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
	look_at(global_position + forward, up)
