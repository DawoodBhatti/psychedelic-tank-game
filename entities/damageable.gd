extends Node
class_name Damageable

# The component that makes an entity killable. Hangs off a Node3D as a plain
# child; the entity itself needs no script, no base class and no knowledge that
# it can be hurt.
#
# WHY A CHILD NODE AND NOT A BASE CLASS. A guardian hull, a prop and (later) the
# player's tank all need hit points, and they are a StaticBody3D, a Node3D and a
# CharacterBody3D respectively. Inheritance would need the behaviour duplicated
# down three trees; composition needs it once, and the difference between a
# fragile prop and an armoured hull becomes a .tres.
#
# WHAT GOES ON THE BUS AND WHAT DOES NOT. `damaged` and `destroyed` are local
# signals for the entity this hangs off - a turret dropping its barrel, a hull
# starting to smoke - because that is a parent-child relationship and routing it
# through a global bus would hide that. `entity_damaged` and `entity_destroyed`
# go on GameEvents because the things that care (HUD, score, audio, the
# objective tracker) are not in this entity's subtree and must not have to find
# it.
#
# THE BUS CARRIES WHAT LANDED, NOT WHAT WAS FIRED. `entity_damaged`'s `amount`
# is post-armour, post-resistance. A listener that pops a damage number wants
# the number that came off the health bar; a listener that wanted the raw figure
# would be asking the weapon, not the target.
#
# OVERKILL IS DISCARDED, INCLUDING ON THE KILLING BLOW. A 742-point hit on an
# entity with 148 left reports 148, not 742, and damage_absorbed on a 240-point
# hull can never exceed 240. This is the one case where "what landed" and "what
# got through the armour" disagree, and the contract above picks the first: a
# HUD that pops "992" over a target with a 240-point health bar is showing a
# number that describes nothing the player can see. Anything that genuinely
# wants the unclamped figure is asking about the WEAPON, which knows what it
# fired without needing the target to tell it.
#
# NOTHING HERE FREES ANYTHING. On reaching zero this flips `is_alive`, announces
# it, and stops. What death LOOKS like - a wreck mesh, an explosion, a respawn,
# a level reset - belongs to the entity and to the sessions that build those. A
# component that queue_free()s its own parent takes that decision away from
# every entity that will ever use it.

## Fired at the entity this hangs off, for its own local reaction. `amount` is
## the damage actually applied.
signal damaged(amount: float, source: Node3D)

## Fired once, at the moment health reaches zero. Never fired twice: further
## damage after death is discarded by apply_damage().
signal destroyed(source: Node3D)

## Hit points, armour and per-type resistance. Left null this pushes an error
## and falls back to a default-constructed profile, so a mis-wired entity is
## loud but still playable.
##
## The evidence that an authored profile is actually live is
## `profile.resource_path` off the live node, NOT `health` - see CLAUDE.md on
## resource references. A .tres whose values happen to match the script's
## defaults reproduces every number a broken resolution would.
@export var profile: DamageProfile

## Current hit points. Written only by apply_damage(), so reading it back is a
## check rather than a re-execution of the thing that set it.
var health: float = 0.0

## False from the moment health first reaches zero.
var is_alive: bool = true

## Everything this entity has absorbed since load, post-armour. Independent of
## `health` for anything that heals or repairs later.
var damage_absorbed: float = 0.0

# The Node3D this component describes. Resolved once, because get_parent() on a
# freed or reparented node is exactly the sort of thing that goes wrong in the
# frame something dies.
var _entity: Node3D


func _ready() -> void:
	if profile == null:
		push_error("Damageable on %s: no DamageProfile assigned - using defaults"
			% get_parent().name)
		profile = DamageProfile.new()

	health = profile.max_health

	_entity = get_parent() as Node3D
	if _entity == null:
		push_error("Damageable must be a child of a Node3D; parent is %s"
			% ("null" if get_parent() == null else get_parent().get_class()))


## The Damageable hanging off `node`, or null. THE ONE DEFINITION OF WHERE THIS
## COMPONENT LIVES RELATIVE TO ITS ENTITY, so a weapon that has just raycast a
## body and a spawner counting survivors agree about what "has hit points" means.
##
## Direct children only, deliberately. A recursive search would find the
## Damageable of something PARENTED to this entity - a turret riding a hull, a
## crate on a truck - and report the passenger's hit points as the vehicle's.
static func of(node: Node) -> Damageable:
	if node == null:
		return null
	for child in node.get_children():
		if child is Damageable:
			return child
	return null


## The entity this component speaks for. What the bus signals carry.
func entity() -> Node3D:
	return _entity


## Applies one hit and returns the damage that actually came off the health bar
## - post-resistance, post-armour, and CLAMPED TO THE HEALTH REMAINING, so the
## return value, the `damaged` signal and `entity_damaged` all carry the same
## number and that number never exceeds what the entity had left.
##
## Public and callable from anywhere: this is the whole API, and it is
## deliberately reachable from --harness-eval on the live node, because that is
## the only way to exercise a damage path with no weapon in the project yet.
func apply_damage(amount: float, type: int = DamageProfile.Type.KINETIC,
		source: Node3D = null) -> float:
	if not is_alive:
		# Overkill is discarded rather than accumulated. Without this a shell
		# landing on a wreck fires entity_destroyed a second time, and every
		# listener that counts kills counts one too many.
		return 0.0

	var applied := profile.damage_taken(amount, type)
	if applied <= 0.0:
		return 0.0

	# The clamp the header argues for. It has to happen BEFORE the subtraction
	# and before anything is emitted, or the three consumers of this number - the
	# return value, the local signal and the bus - would not all agree.
	applied = minf(applied, health)

	health = maxf(health - applied, 0.0)
	damage_absorbed += applied

	damaged.emit(applied, source)
	GameEvents.entity_damaged.emit(_entity, applied, source)

	if health <= 0.0:
		is_alive = false
		destroyed.emit(source)
		GameEvents.entity_destroyed.emit(_entity, source)

	return applied


## 0.0 dead, 1.0 untouched. What a health bar reads.
func health_fraction() -> float:
	if profile == null or profile.max_health <= 0.0:
		return 0.0
	return clampf(health / profile.max_health, 0.0, 1.0)
