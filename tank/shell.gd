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

## THE REFERENCE HIT, AND THE ONE PLACE IT IS WRITTEN DOWN.
##
## "Five shells kill a tower" is arithmetic over two numbers that live in
## different files - this one and `entities/profiles/tower.tres`'s max_health -
## and the way that goes wrong is for someone to retune one and read the other
## off a comment. So the profile is authored at 5 x this (100.0), and
## `Tower.hits_to_kill()` DIVIDES rather than repeating the 5: retune this
## constant and the tower's crack stages re-derive themselves, and a mismatch
## shows up as a non-integer hit count instead of as a tower that dies on the
## fourth shell.
##
## A const rather than a plain default so the harness can read it -
## `get_script().get_script_constant_map()["NOMINAL_DAMAGE"]` - and check the
## arithmetic against the live profile in one eval. Plain `get()` cannot see a
## const, and an @export default is not visible on the class at all.
const NOMINAL_DAMAGE := 20.0

## Blast radius handed to the terrain. This is what "how big a hole" means.
@export var blast_radius: float = 8.0

## Damage one hit applies to whatever it lands on, before that target's armour
## and resistance. Per-shell rather than per-target: the weapon knows what it
## fired, and Damageable owns what got through.
@export var damage: float = NOMINAL_DAMAGE

## What the hit is made of, indexing DamageProfile.Type. Solid shot - the crater
## is a side effect of a kinetic round arriving, not a separate explosive
## payload, and nothing in the project fires EXPLOSIVE yet.
@export var damage_type: int = DamageProfile.Type.KINETIC

## Seconds before an unhit shell gives up. A shell fired at the sky must not
## live for ever.
@export var lifetime: float = 12.0

@export var gravity: float = -22.0

## Layers the shell can hit. Deliberately does NOT include the tank's layer: a
## shell that masked its own firer would detonate on the barrel it left.
##
## TERRAIN AND STRUCTURES, ADDED TOGETHER WITH THE DAMAGE THAT MAKES THE BIT
## WORTH MASKING. This row was terrain-only until S4, and the comment that lived
## here said adding enemies was "session E's change" - a session that no longer
## exists anywhere: S2 cancelled that plan and docs/roadmap.md is the backlog
## now. The reasoning it carried is worth keeping though, because it is the rule
## this session had to satisfy to widen the mask at all: masking a bit the shell
## cannot damage buys a detonation that visibly connects and takes zero hit
## points off, which is the exact failure DamageProfile.min_damage_fraction
## exists to prevent one layer up. _detonate() now applies damage, so the bit
## has earned its place.
##
## ENEMIES is still absent, and that is again the same rule: nothing is on that
## layer today. It goes in with S4c's red tanks, in the session that gives them
## a Damageable to take the hit.
##
## Not stored in shell.tscn - this default is the only place the value lives.
@export_flags_3d_physics var hit_mask: int = CollisionLayers.TERRAIN \
	| CollisionLayers.STRUCTURES

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

	_detonate(hit["position"], hit.get("normal", Vector3.UP), hit.get("collider"))


func _detonate(at: Vector3, normal: Vector3, collider: Object = null) -> void:
	# DAMAGE FIRST, THEN THE BLAST. The order is not cosmetic: shell_exploded is
	# the bus event the effects director and (later) the terrain listen to, and a
	# listener that reacted by resetting the level would otherwise run before the
	# hit it was reacting to had been applied.
	#
	# It is also why this takes the collider rather than looking one up from the
	# position: the raycast already knows exactly what was struck, and a second
	# query against the same point could pick a different body.
	var target := Damageable.of(collider as Node)
	if target != null:
		target.apply_damage(damage, damage_type, self)

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
