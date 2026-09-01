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

## Damage the blast does to something standing AT the centre but not struck -
## before falloff, armour and resistance.
##
## A SEPARATE AUTHORED NUMBER, NOT A FRACTION FOLDED INTO THE CURVE. "A near
## miss does 40% of a hit" is a feel dial, and a dial hidden inside a falloff
## expression is a dial nobody can find. Derived from NOMINAL_DAMAGE rather than
## written as 8.0 for the reason that const exists: retune the reference hit and
## the near miss follows it.
@export var splash_damage: float = NOMINAL_DAMAGE * 0.4

## What the splash is worth at exactly `blast_radius`, as a fraction of
## `splash_damage`. The FLOOR of the falloff, not its end: past the radius the
## curve does not tail off, it stops (see splash_damage_at).
##
## A const so the harness can read it and check the falloff arithmetic in one
## eval, the same way NOMINAL_DAMAGE is read.
const SPLASH_EDGE_FRACTION := 0.25

## Bodies one blast may damage. Only a ceiling on the physics query - the glen
## holds six towers and one terrain body, so it is never reached in practice. It
## exists because intersect_shape() silently truncates rather than reporting that
## it did.
const MAX_BLAST_TARGETS := 32

## How far past `blast_radius` still counts as AT the edge.
##
## A ROUNDING GUARD, NOT A FEEL DIAL, and it is not decoration - it is the same
## shape of defect as Tower.STAGE_EPSILON, arriving through Vector3 instead of
## through a division. Vector3 is 32-bit, so a point built as "the target, plus
## the radius along one axis" nine hundred units from the origin lands
## 8.0 +/- 6e-5 away rather than exactly 8.0. Without a guard the SIGN of that
## rounding decides between the floor and zero: a coin flip dressed up as a
## falloff, and one that reads as "the blast edge does nothing" half the time it
## is measured.
##
## A millimetre is far below anything the game can resolve and far above the
## ~1e-4 the arithmetic can be wrong by at world scale, so it cannot let a
## genuine miss through.
const EDGE_TOLERANCE := 0.001

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
## ENEMIES JOINED IN S4c, under that same rule and not before it: the red tanks
## arrived with a Damageable and an authored profile in the same session, so the
## bit was never masked without damage behind it. The mask-rather-than-a-second-
## list rule still holds - there is only ever one place that says what a shell may
## hurt, and it is this line.
##
## BUT THE BIT BUYS DIRECT HITS ONLY, NOT SPLASH, AND THAT IS MEASURED. The two
## halves of this file ask the physics server different questions:
## _physics_process casts a RAY, and _damageables_in_blast() casts a SHAPE. Under
## this project's Jolt backend intersect_shape() does not report a
## CharacterBody3D at all, while intersect_ray() does. So adding ENEMIES is what
## makes the swept ray find a red tank and kill it, and the blast query at the
## same tank returns nothing.
##
## Measured rather than reasoned: _damageables_in_blast() at an enemy's origin
## returns 0, at its hull centre (+ Vector3(0, 0.75, 0)) returns 0, and at a
## tower's origin returns 1; a live shell with velocity (-300, 0, 0) and one
## _physics_process(0.2) took that same enemy 20.0 -> 0.0 with crater_count()
## still 0, so the ray struck the body rather than the ground under it.
##
## IT IS NOT A PROPERTY OF THE ENEMY. The player's own tank is a CharacterBody3D
## and is equally invisible to the blast query - adding PLAYER to this mask
## temporarily reported 0 splash targets standing on top of it. Anything that
## later wants a blast to reach a character body needs a different query, not a
## different bit here.
##
## PLAYER IS STILL ABSENT AND MUST STAY ABSENT. It is the only thing stopping the
## firer being caught in his own blast, and now that something on the map can
## kill him it is the difference between a near miss and a suicide.
##
## Not stored in shell.tscn - this default is the only place the value lives.
@export_flags_3d_physics var hit_mask: int = CollisionLayers.TERRAIN \
	| CollisionLayers.ENEMIES | CollisionLayers.STRUCTURES

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
	apply_blast(at, collider as Node)

	# Pull the crater centre slightly INTO the surface along its normal.
	# Detonating exactly on the surface removes a hemisphere and leaves a
	# shallow scrape; sinking it by a third of the radius gives a hole that
	# reads as a hole. Anything deeper starts tunnelling under the ground and
	# leaving a thin crust the tank falls through.
	var centre := at - normal * (blast_radius * 0.33)

	GameEvents.shell_exploded.emit(centre, blast_radius)
	queue_free()


## Everything this shell does to hit points at `at`: the full `damage` to
## `direct_target`, and the falloff splash to every OTHER damageable body inside
## `blast_radius`.
##
## THE EXCLUSION, NAMED. `direct_target` takes the direct hit and is then SKIPPED
## by the splash loop - the `if splashed == direct` below is the whole of it.
## Without that line a shell landing dead-on a tower is caught by its own blast
## and pays twice, which reads as "direct hits do double damage" and passes every
## test in the sequence, because nothing in the sequence knows what one hit is
## supposed to cost. Pass null for a blast that struck no body (a shell into the
## dirt beside a tower); then nothing is excluded and everything in range takes
## splash.
##
## PUBLIC, AND FOR THE SAME REASON Tank.fire() IS. A shell only reaches _detonate
## through _physics_process, and no frame runs inside a --harness-eval batch, so
## the branch body has to be callable directly or the damage numbers cannot be
## measured on live nodes at all.
##
## The returned dictionary is a CONVENIENCE, not evidence: it is computed by this
## function, so reading it back proves nothing about hit points. Read
## `Damageable.health` on the targets.
func apply_blast(at: Vector3, direct_target: Node = null) -> Dictionary:
	var report := {"direct": 0.0, "splash_targets": 0, "splash_total": 0.0}

	var direct := Damageable.of(direct_target)
	if direct != null:
		report["direct"] = direct.apply_damage(damage, damage_type, self)

	for splashed in _damageables_in_blast(at):
		if splashed == direct:
			continue
		var amount := splash_damage_at(at.distance_to(splashed.entity().global_position))
		if amount <= 0.0:
			continue
		var applied := splashed.apply_damage(amount, damage_type, self)
		if applied > 0.0:
			report["splash_targets"] += 1
			report["splash_total"] += applied

	return report


## Splash damage at `distance` from the blast centre, before the target's armour
## and resistance.
##
## FULL AT THE CENTRE, A FLOOR AT THE RADIUS, ZERO BEYOND IT. The floor is what
## makes this a falloff rather than a constant with a hard edge; the zero is what
## makes the radius mean something. Both matter: a curve that reached zero
## exactly at the radius would be indistinguishable from no blast at all for
## anything standing near the edge, and one that carried on past it would make
## blast_radius a lie the terrain and the effects both already tell the truth
## about. "Beyond" means beyond by more than EDGE_TOLERANCE - see that const.
##
## Linear rather than inverse-square: this is a feel dial, and a designer reading
## "quarter damage at the edge" off SPLASH_EDGE_FRACTION can predict the number
## at half the radius without arithmetic.
func splash_damage_at(distance: float) -> float:
	if distance > blast_radius + EDGE_TOLERANCE:
		return 0.0
	if blast_radius <= 0.0:
		return splash_damage
	var t := clampf(distance / blast_radius, 0.0, 1.0)
	return splash_damage * lerpf(1.0, SPLASH_EDGE_FRACTION, t)


# Every distinct Damageable whose body overlaps the blast, filtered by hit_mask.
#
# hit_mask RATHER THAN A SECOND "WHAT CAN I HURT" LIST, and that is the rule the
# mask's own comment sets out: the bits a shell masks are the bits it can damage.
# It also means the player is not caught by his own splash - PLAYER is deliberately
# absent from the mask.
#
# WHAT THE MASK CANNOT BUY HERE, MEASURED IN S4c: this query returns nothing for a
# CharacterBody3D under Jolt, whatever bits are set. Both tanks in the game are
# CharacterBody3Ds, so ENEMIES in the mask makes the swept ray in
# _physics_process() find a red tank and kill it outright, and leaves this
# function unable to see the same tank standing at the blast's centre. Splash
# reaches the towers, which are StaticBody3Ds, and nothing else.
#
# So DO NOT read "it is in hit_mask" as "it can be splashed" - the two came apart
# here. See the hit_mask docblock for the numbers, including the control that
# rules out this being something about the enemy rather than about the query.
#
# DEDUPED, and that is not tidiness. intersect_shape() reports one result per
# SHAPE, and a tower carries two CollisionShape3Ds (shaft and cap), so an
# un-deduped loop applies splash to the same tower twice - the same double-damage
# failure the direct-hit exclusion above exists to prevent, arriving through the
# query instead of through the caller.
#
# A physics query rather than a group or a registry: the bodies were added to the
# tree at load and the broadphase has stepped many times since, so this has none
# of the same-frame staleness Spawner._is_clear() avoids analytics for.
func _damageables_in_blast(at: Vector3) -> Array[Damageable]:
	var out: Array[Damageable] = []

	var world := get_world_3d()
	if world == null:
		return out

	var sphere := SphereShape3D.new()
	sphere.radius = blast_radius

	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = sphere
	query.transform = Transform3D(Basis.IDENTITY, at)
	query.collision_mask = hit_mask
	query.collide_with_bodies = true
	query.collide_with_areas = false

	for hit in world.direct_space_state.intersect_shape(query, MAX_BLAST_TARGETS):
		var found := Damageable.of(hit.get("collider") as Node)
		if found != null and not out.has(found):
			out.append(found)

	return out


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
