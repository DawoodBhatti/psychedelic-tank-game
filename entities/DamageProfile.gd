extends Resource
class_name DamageProfile

# How much punishment one entity takes, and what it takes it badly from.
#
# This is the DATA half of Damageable. The component is the same for a guardian
# hull, a prop and (later) the player's tank; only this resource differs, which
# is what the foundation plan means by "components configured by exported
# Resources, not inheritance".
#
# SIGN AND ORDER MATTER. Damage is scaled by the type resistance FIRST and only
# then reduced by flat armour. The other order makes armour worth more against
# the type an entity already resists, which is backwards - armour is plate, and
# plate does not care what it already shrugged off.

## What a hit is made of. Values are stable ints: they are written into .tres
## files as array indices, so inserting a new type in the MIDDLE would silently
## re-map every authored resistance array. Append only.
enum Type {
	KINETIC = 0,   ## Solid shot. The default, and what a tank shell is.
	EXPLOSIVE = 1, ## Blast. What a crater-carving round does to anything nearby.
	ENERGY = 2,    ## Beams and fields. Nothing fires this yet.
}

## Hit points at full health.
@export var max_health: float = 100.0

## Flat points subtracted from every hit AFTER the type resistance is applied.
## Armour is what makes a light weapon useless against a heavy hull rather than
## merely slow.
@export var armour: float = 0.0

## Multiplier per damage type, INDEX-ALIGNED TO `Type`. Entries past the end of
## the array default to 1.0, so a profile that leaves this empty simply takes
## every type at face value - the safe default.
##
## Index-aligned rather than a Dictionary keyed by the enum for the reason
## SDFComposite gives for its parallel arrays: this is authored in a .tres, and
## a packed array of floats is the shape a .tres writes cleanly.
@export var resistance: PackedFloat32Array = PackedFloat32Array()

## The smallest fraction of an incoming hit that armour can never absorb.
##
## WITHOUT THIS, `armour >= damage` IS INVULNERABILITY, and it does not look
## like invulnerability - it looks like a weapon that fires, flashes, carves the
## ground and does nothing, which is a bug report about the gun. A floor turns
## an over-armoured entity into a slow kill instead of an impossible one.
@export var min_damage_fraction: float = 0.1


## Multiplier for one damage type. Out-of-range and unauthored types are 1.0.
func resistance_for(type: int) -> float:
	if type < 0 or type >= resistance.size():
		return 1.0
	return resistance[type]


## What `amount` of `type` actually costs this profile in hit points. Pure - it
## holds no state, so the same call twice gives the same answer and Damageable
## owns the running total.
func damage_taken(amount: float, type: int) -> float:
	if amount <= 0.0:
		return 0.0
	var scaled := amount * resistance_for(type)
	return maxf(scaled - armour, scaled * min_damage_fraction)
