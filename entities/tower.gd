extends StaticBody3D
class_name Tower

# A tower that cracks as it is shot and dies on the fifth hit.
#
# WHAT IT ADDS TO THE PARTS IT IS MADE OF. Damageable already owns hit points and
# announces damage; SkinSlot already owns what the thing looks like. Neither
# knows about the other, on purpose - the component is shared with anything else
# that will ever be killable, and the skin slot is shared with anything that will
# ever be re-skinned. This script is the ONE place those two meet, and it is the
# whole of what "destructible" costs on top of them.
#
# THE SIGNAL IS LOCAL, NOT THE BUS. `damaged` is a plain child-to-parent signal
# because a tower reacting to its own damage is a parent-child relationship, and
# routing it through GameEvents would hide that (CLAUDE.md, Code standards).
# Damageable still puts `entity_damaged` on the bus for the HUD and anything else
# outside this subtree; the two are not alternatives.
#
# FIVE HITS IS DERIVED, NOT WRITTEN DOWN TWICE. hits_to_kill() divides the
# authored max_health by Shell.NOMINAL_DAMAGE. Nothing enforces that the answer
# is a whole number, so the harness gate is what checks it - and a mismatch shows
# up as hits_to_kill() moving, which is a number a test can fail on, rather than
# as a tower that quietly dies on the fourth shell.
#
# WHY hits_to_kill() DIVIDES INSTEAD OF BEING AN @export. An exported "5" is a
# third copy of a fact that already exists twice (the profile's 100 and the
# shell's 20), and the copy is the one that goes stale. Retuning either end
# re-derives the stages here with no edit at all.
#
# NOTHING IS FREED ON DEATH, and that follows Damageable's contract rather than
# working around it. A destroyed tower stays standing as a fully fractured,
# unlit hulk: it keeps its collision, so the glen does not develop invisible gaps
# where landmarks used to be, and `towers_alive` moves off `is_alive` rather than
# off the node count, so a kill is visible to the harness without anything having
# to remember it happened.

## The visuals, and the only node allowed to know what a tower looks like.
@onready var skin: SkinSlot = $Skin

## Hit points. Its DamageProfile is entities/profiles/tower.tres, authored at
## 5 x Shell.NOMINAL_DAMAGE.
@onready var damageable: Damageable = $Damageable

# Rounding guard for the stage quantiser, and it is not decoration.
#
# The obvious form of the stage - floor((1 - health_fraction()) * hits) / hits -
# is off by one at the very first hit, in double precision, for the exact numbers
# this tower ships with. 80.0 / 100.0 is not 0.8 but the next double ABOVE it, so
# 1.0 - that is 0.19999999999999996, times 5 is 0.9999999999999998, and floor()
# takes it to 0: one shell landed, health moved, and the tower did not visibly
# change. That is the "looks like the signal never fired" failure this project
# keeps meeting, arriving through arithmetic instead of through a stale mirror.
#
# 1e-4 is far below one stage (0.2 here, and 0.01 even at a hundred hits) and far
# above the ~1e-16 the division can be wrong by, so it cannot round a genuinely
# unfinished stage up.
const STAGE_EPSILON := 1e-4

## Crack stage actually written to the material: 0.0 undamaged, 1.0 destroyed,
## quantised to whole hits so the player can count them.
##
## WRITTEN ON THE CODE PATH THAT SETS IT - in the `damaged` handler and once at
## _ready() - never mirrored in _process(). A per-frame copy reports its
## pre-batch value to any harness eval that changed it in the same batch, which
## reads as "nothing happened" about something that did (main.gd:62, CLAUDE.md on
## the eval batch). This is also the value to read INSTEAD of the material: the
## shader parameter is what this change writes, so reading it back would be a
## re-execution rather than a check.
var crack_stage: float = 0.0


func _ready() -> void:
	# THE ONE PLACE THIS BODY'S LAYERS ARE ASSIGNED - not tower.tscn. See
	# CollisionLayers' header for why the script wins and why a .tscn value
	# silently overridden here would be a comment that lies.
	#
	# Mask 0, like the terrain's static body: a tower detects nothing. It is
	# DETECTED - by the tank's chassis, which masks STRUCTURES, and by the
	# shell's raycast, whose collision_mask includes STRUCTURES. Both of those
	# are one-directional queries against this body's LAYER, so giving it a mask
	# of its own would buy nothing and imply a relationship that does not exist.
	collision_layer = CollisionLayers.STRUCTURES
	collision_mask = 0

	if damageable == null:
		push_error("Tower %s: no Damageable child - it cannot be destroyed" % name)
		return

	damageable.damaged.connect(_on_damaged)
	# Start clean rather than at whatever the material was last saved with. A
	# shader parameter is part of a shared resource on disk; leaving it wherever
	# it was left is how a debug state ships (main.gd does the same for
	# trip_amount).
	_set_crack(0.0)


## Shells needed to destroy this tower, from the authored profile and the shell's
## reference damage. Read it rather than assuming 5: it is the number the crack
## stages are quantised to, and the arithmetic behind "five hits" in one call.
##
## Zero when there is no profile to divide - a tower that cannot be hurt has no
## hit count, and 0 fails a gate where a silent 1 would pass one.
func hits_to_kill() -> int:
	if damageable == null or damageable.profile == null:
		return 0
	if Shell.NOMINAL_DAMAGE <= 0.0:
		return 0
	return int(round(damageable.profile.max_health / Shell.NOMINAL_DAMAGE))


## Hits this tower has left, from live health rather than from a counter. Derived
## differently from crack_stage - health divided by the reference hit, against
## crack_stage's health FRACTION times the hit count - so the two disagreeing is
## itself informative.
func hits_remaining() -> int:
	if damageable == null or Shell.NOMINAL_DAMAGE <= 0.0:
		return 0
	return int(ceil(damageable.health / Shell.NOMINAL_DAMAGE - STAGE_EPSILON))


func _on_damaged(_amount: float, _source: Node3D) -> void:
	_set_crack(_stage_for(damageable.health_fraction()))


# Health fraction rounded DOWN to a whole hit. Rounding down rather than to
# nearest is what makes the last stage before death distinct from death itself:
# at 1/5 health the tower is visibly wrecked and still standing.
func _stage_for(fraction: float) -> float:
	var hits := hits_to_kill()
	var damage := 1.0 - clampf(fraction, 0.0, 1.0)
	if hits <= 0:
		# No profile to quantise against. Continuous is wrong but visible, which
		# beats a tower that never changes because its arithmetic divided by zero.
		return damage
	var stage := floori(damage * float(hits) + STAGE_EPSILON)
	return clampf(float(stage) / float(hits), 0.0, 1.0)


# Writes the stage to every mesh under the skin, as a PER-INSTANCE shader
# parameter rather than to the material.
#
# Per instance because all six towers share one ShaderMaterial: a plain
# set_shader_parameter() would crack the whole set on the first hit anywhere,
# and duplicating the material per tower would put the look in a second place
# (see the shader's header).
#
# The meshes are re-collected on every write rather than cached in _ready().
# SkinSlot.set_skin() can replace the entire subtree at any time, and a cached
# list would then hold freed nodes and silently stop cracking anything - the
# failure being invisible, because writing a parameter to nothing raises nothing.
func _set_crack(stage: float) -> void:
	crack_stage = stage
	if skin == null:
		return
	for node in _skin_geometry(skin):
		node.set_instance_shader_parameter("damage_amount", stage)


# Every GeometryInstance3D under the skin, at any depth: a real model arrives as
# a nested scene, not as one mesh.
func _skin_geometry(node: Node) -> Array[GeometryInstance3D]:
	var out: Array[GeometryInstance3D] = []
	for child in node.get_children():
		if child is GeometryInstance3D:
			out.append(child)
		out.append_array(_skin_geometry(child))
	return out
