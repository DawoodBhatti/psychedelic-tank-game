extends CharacterBody3D
class_name EnemyTank

# A red tank that roams a circular patch, drives at the player the moment it can
# SEE him, and goes home once he has drawn it too far from that patch.
#
# ============================================================
# WHY THIS IS NOT A `Tank`
# ============================================================
# tank.gd is 372 lines of INPUT: mouse look, a camera arm, a reload timer, a
# respawn path that emits level_reset_requested. An AI wants none of it, and
# inheriting it would mean every change to how the player FEELS silently edits
# how the enemy BEHAVES. So this is its own body with its own tiny drive loop.
#
# WHAT IS SHARED IS THE FEEL, AND ONLY THE FEEL. FORWARD_DRIVE, TURN_RATE and
# DRAG_COEFF are named off Tank rather than re-typed, so a red tank accelerates,
# turns and coasts exactly like the player's and a retune moves both. They are
# `const`s on Tank precisely so they can be read this way - by this script at
# parse time, and by the harness through get_script_constant_map(). Re-declaring
# them here as consts (rather than reading Tank's at every call site) is what
# keeps them harness-readable OFF THIS NODE: a value that only exists on another
# class cannot be measured on a live enemy.
#
# `gravity` is the one number that IS copied rather than shared, and that is
# Tank's fault rather than a choice: it is an @export there, which is invisible
# to the class, so there is nothing to name. It is exported here for the same
# reason it is exported there.
#
# ============================================================
# WHICH DISTANCE THE LEASH IS MEASURED ON, AND WHY
# ============================================================
# THE LEASH IS THE PLAYER'S DISTANCE FROM THE PATROL CENTRE, not this tank's.
#
# Three reasons, in order of how much they decided it:
#
#   1. It is what makes should_leash() a FUNCTION OF A POSITION. Leashing on the
#      enemy's own distance from home needs no argument at all - it would read
#      its own transform - and a predicate with no argument cannot be asked
#      "what would you do if he were over there?" without moving him there
#      first. Taking the position is what lets the whole thing be tested with no
#      frame passing (CLAUDE.md, on the eval batch).
#   2. It is the rule the player can actually play against: "get 3 patrol radii
#      away from where he lives and he gives up". The enemy's own distance from
#      home is a number the player cannot see and cannot control.
#   3. The two agree in the case that matters anyway. An engaging enemy drives
#      AT the player, so once it has closed, its distance from home and his are
#      the same number.
#
# Distances are FLAT (x/z only), which is Spawner._flat_distance()'s rule and
# for its reason: a patrol patch is a footprint on the ground, and a player
# fifty units up a hillside has not escaped anything.
#
# ============================================================
# WHY THE STATE MACHINE CANNOT CHATTER
# ============================================================
# Two guards, and the first one is the load-bearing one.
#
#   AGGRO IS ONLY ACQUIRED FROM INSIDE THE CIRCLE (`_contained`). Leash a tank
#   while it is standing next to the player and it is, for that instant, both
#   beyond its leash and well inside its sight range - so without this it would
#   re-acquire on the very next frame and the two states would alternate for
#   ever. Requiring it to get home first turns "give up and go home" into
#   something it has to finish.
#
#   SIGHT RANGE IS HELD BELOW 2 x THE PATROL RADIUS. A patrolling tank is inside
#   its circle, so the furthest-away player it can ever acquire is
#   patrol_radius + sight_range from the centre; keeping that under the leash
#   distance of 3 x patrol_radius means an acquisition can never be leashed on
#   the same frame it happens. That inequality is why the multiplier is 3 and
#   not 1.1, and it is asserted in _ready() rather than left as a comment.
#
# LOSING SIGHT DOES NOT DISENGAGE - only distance does. A tank that gave up the
# moment the player ducked behind a rock would be un-fightable, and the
# hysteresis above only works because there is exactly one way out of ENGAGING.
#
# ============================================================
# WHAT IT DOES NOT DO
# ============================================================
# It does not shoot, does not path around obstacles, does not talk to other
# enemies and knows nothing about what its own death is worth to the player -
# the level owns that (see main.gd's _on_entity_destroyed). It does not emit
# level_reset_requested either: dying is the PLAYER's reset, and an enemy
# borrowing that path would restart the run every time one was killed.

## PATROLLING covers both wandering inside the circle and driving home from
## outside it. There is deliberately no third RETURNING state: "outside my
## circle" is already readable off the transform, and a state that only exists
## to say so is a state that can disagree with the geometry.
enum State { PATROLLING, ENGAGING }

const STATE_NAMES := ["patrolling", "engaging"]

# ============================================================
# Drive - shared with the player's tank, see the header
# ============================================================
const FORWARD_DRIVE := Tank.FORWARD_DRIVE
const TURN_RATE := Tank.TURN_RATE
const DRAG_COEFF := Tank.DRAG_COEFF

## Falls at the player's rate. Copied rather than named because Tank's is an
## @export; see the header.
@export var gravity: float = -26.0

# ============================================================
# Patrol
# ============================================================
## Radius of the patch this tank roams, in world units. The CENTRE is not
## authored - it is wherever the level put this tank (see _capture_centre), so a
## scattered enemy patrols where it was scattered and no .tres names a
## coordinate the procedural valley would invalidate.
@export var patrol_radius: float = 110.0

## Multiplier on patrol_radius at which an engaged tank gives up. See the header
## for which distance it is measured on.
const LEASH_MULTIPLIER := 3.0

## Waypoints are drawn inside this fraction of the radius, so ordinary wandering
## never aims at the fence.
const WAYPOINT_FRACTION := 0.7

## Past this fraction of the radius the destination becomes the centre whatever
## the current waypoint was. This is the steering half of containment; the
## velocity fence below is the guarantee.
const CONTAINMENT_FRACTION := 0.85

## Close enough to a waypoint to call it reached.
const WAYPOINT_ARRIVAL := 6.0

## Seconds before a waypoint is abandoned. Nothing here paths around obstacles,
## so a tank wedged against a tower would otherwise push at it for ever.
const WAYPOINT_TIMEOUT := 12.0

# ============================================================
# Senses
# ============================================================
## How far this tank can see, as a FLAT distance. Flat rather than true 3D range
## so that "the same range" means the same thing for two targets standing at
## different heights - which is exactly the pair that separates a raycast from a
## distance test.
##
## MUST STAY UNDER 2 x patrol_radius; _ready() checks it. See the header.
@export var sight_range: float = 200.0

## Height of this tank's eye above its origin - about the top of the turret.
@export var eye_height: float = 1.7

## Height above the TARGET's origin that the sightline is drawn to. A tank's
## origin sits at the bottom of its tracks, and a ray aimed there grazes the
## ground it is standing on and reports every target as hidden.
@export var target_height: float = 1.3

## What the level told this tank to hunt. SET BY THE LEVEL, never found by this
## script: an enemy that goes looking for the player has to know the game
## contains one, which is the coupling main.gd's header exists to prevent.
## TerrainSurface.follow_target is the same arrangement for the same reason.
var target: Node3D

# ============================================================
# Components
# ============================================================
## The visuals, and the only node allowed to know what this looks like. "Red" is
## its material_override, not a mesh authored red - see enemy_tank.tscn.
@onready var skin: SkinSlot = $Skin

## Hit points. Its DamageProfile is entities/profiles/enemy_tank.tres, authored
## at 1 x Shell.NOMINAL_DAMAGE - see hits_to_kill(), which divides rather than
## repeating the 1.
@onready var damageable: Damageable = $Damageable

# ============================================================
# State
# ============================================================
## Which state this tank is in, as a State value. WRITTEN ON THE CODE PATH THAT
## SETS IT (_enter), never mirrored per frame, for the reason main.gd:62 sets
## out at length.
var state: int = State.PATROLLING

## Centre of the patrol patch, in world space. Captured on the first physics
## frame; see _capture_centre for why not in _ready().
var patrol_centre: Vector3 = Vector3.ZERO

## Current speed in m/s, the same quantity Tank.speed is.
var speed: float = 0.0

# ------------------------------------------------------------
# Measurement-facing state
# ------------------------------------------------------------
# THESE ARE ACCUMULATORS RECORDED ON THE CODE PATH THAT WRITES THEM, not values
# mirrored each frame from somewhere else. Everything here only exists ACROSS
# frames, and no frame runs inside a --harness-eval batch, so there is no other
# way to ask "where did it actually go?" - a transform is a claim about one
# instant. This is PerfSampler's pattern and Terrain.last_carve_clearance's,
# applied to the one thing this file decides: where a tank ends up over time.

## Furthest this tank has been from its patrol centre WHILE PATROLLING AND
## CONTAINED - see _track_patrol for what contained means and why the walk home
## after a leash is excluded from it.
##
## READ IT WITH patrol_frames. Zero over zero frames is not a tank that stayed
## home, it is a tank nobody watched, and the two are otherwise identical.
##
## HOW MUCH TRAVEL A HAND-TICKED SAMPLE ACTUALLY BUYS, because the next session
## will otherwise re-discover it. No harness command runs frames and THEN reads,
## so this is sampled by calling _physics_process(dt) directly N times - and
## move_and_slide() IGNORES the dt passed that way. It uses the engine's own
## physics delta: with velocity (0, 0, -20), one bare move_and_slide() moved the
## body 0.1547 units, which is 7.7 ms of travel and not the 16.6 ms handed in. So
## 300 hand ticks apply about 5 s of thrust and produce about 2.3 s of movement,
## and the excursion they sample is correspondingly short of what 300 engine
## frames would give.
##
## It is sound for what it is asked - a maximum that never crossed the radius is
## still a maximum that never crossed the radius - but it is why the "comes back
## inside the circle" half of S4c's gate could not be closed by measurement and
## was argued from _steer_target() returning the centre instead.
var max_patrol_excursion: float = 0.0

## Physics frames counted into max_patrol_excursion.
var patrol_frames: int = 0

## Times the velocity fence has had to cancel outward motion at the circle's
## edge. Zero means the steering alone kept this tank in, which is a different
## (and better) reason for a good excursion number than "the fence caught it".
var patrol_fence_stops: int = 0

## Times this tank has gone from patrolling to engaging, incremented INSIDE the
## transition.
##
## WHAT IT IS FOR. can_see() being correct proves the predicate; it does not
## prove the state machine consults it. This number moves only on the branch
## that reads can_see(), so a run in which the player is parked in view and this
## stays at 0 is a machine that ignores its own senses.
var aggro_transitions: int = 0

## Times this tank has given up and gone home. The other half of the pair.
var leash_transitions: int = 0

var _centre_captured: bool = false
var _contained: bool = false
var _waypoint: Vector3 = Vector3.ZERO
var _waypoint_age: float = 0.0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	# THE ONE PLACE THIS BODY'S LAYERS ARE ASSIGNED - not enemy_tank.tscn. See
	# CollisionLayers' header for why the script wins and why a .tscn value
	# silently overridden here would be a comment that lies.
	#
	# Layer ENEMIES, which S4 was told to leave alone for exactly this. Masking
	# TERRAIN (it drives on the ground), PLAYER (the two tanks shunt each other
	# rather than interpenetrating - the tank already masks ENEMIES back) and
	# STRUCTURES (a tower stops it, the same reason the player's chassis masks
	# that bit).
	#
	# NOT ENEMIES: red tanks do not collide with each other, so a pair whose
	# patrol circles overlap does not spend the level shoving itself apart. That
	# is the historical EnemyBody's ruling, kept.
	collision_layer = CollisionLayers.ENEMIES
	collision_mask = CollisionLayers.TERRAIN | CollisionLayers.PLAYER \
		| CollisionLayers.STRUCTURES

	# Deterministic per tank, so the same level wanders the same way on every
	# launch and a before/after screenshot stays comparable. Seeded from the
	# node NAME because the Spawner has already made it unique ("enemy_0") and
	# the position is not known yet - see _capture_centre.
	_rng.seed = hash(String(name))

	if damageable == null:
		push_error("EnemyTank %s: no Damageable child - it cannot be killed" % name)

	# The no-chatter inequality from the header, checked rather than trusted. It
	# is a relationship between two authored numbers, so nothing but an assertion
	# at load will notice when one of them is retuned.
	if sight_range >= patrol_radius * 2.0:
		push_error(("EnemyTank %s: sight_range %.1f must stay under 2 x patrol_radius"
			+ " %.1f, or an acquisition can be leashed on the frame it happens")
			% [name, sight_range, patrol_radius])


func _physics_process(delta: float) -> void:
	if not _centre_captured:
		_capture_centre()

	if not is_alive():
		# A wreck keeps its collision and its transform and simply stops taking
		# orders, which is Tank's rule for a destroyed hull and Tower's for a
		# destroyed tower. It does NOT reset the level and it is not freed -
		# `enemies_alive` moves off Damageable.is_alive, so a kill is visible
		# without anything having to remember it happened.
		return

	_update_state()
	_drive(_steer_target(delta), delta)
	_track_patrol()


# ------------------------------------------------------------
# Senses - pure predicates, callable with any position
# ------------------------------------------------------------
## Whether this tank can see something standing at `from_position`.
##
## A POSITION ARGUMENT RATHER THAN A LOOK AT THE WORLD, and that is the whole
## reason the aggro half of this file is testable. No frame runs inside a
## --harness-eval batch, so "move the player, wait, read the state" is not a
## thing that can be asked; two calls with two positions is. It is also the
## project's existing ruling for input bindings - call the branch body directly -
## applied to a sensor.
##
## RANGE THEN RAYCAST, and the raycast is the half that matters. A distance-only
## check passes every positive test ever written for it; the only thing that
## separates it from this is a target at the SAME range with a hill in the way.
## The ray is against TERRAIN alone, so towers do not provide cover - a decision,
## not an oversight, and the one line to change if they should.
func can_see(from_position: Vector3) -> bool:
	if _flat_distance(global_position, from_position) > sight_range:
		return false

	var space := get_world_3d().direct_space_state
	if space == null:
		# No world to query. False rather than true: a sensor that cannot
		# measure must not report the answer that starts a fight.
		return false

	# No exclude list is needed - the mask is TERRAIN, and this body is on
	# ENEMIES, so it cannot occlude itself.
	var query := PhysicsRayQueryParameters3D.create(
		global_position + Vector3.UP * eye_height,
		from_position + Vector3.UP * target_height)
	query.collision_mask = CollisionLayers.TERRAIN

	return space.intersect_ray(query).is_empty()


## Whether something at `from_position` has drawn this tank far enough from home
## for it to give up. See the header for which distance this is and why.
func should_leash(from_position: Vector3) -> bool:
	return _flat_distance(from_position, patrol_centre) > leash_range()


## The distance should_leash() compares against, in world units. Derived rather
## than authored, so retuning patrol_radius moves the leash with it.
func leash_range() -> float:
	return patrol_radius * LEASH_MULTIPLIER


# ------------------------------------------------------------
# Measurements
# ------------------------------------------------------------
## How much room this tank had to spare inside its own patrol circle: the radius
## minus the furthest it ever got from the centre while patrolling.
##
## Positive means containment held with that much margin; zero or below means it
## crossed its own fence. THE CLEARANCE, in the sense Spawner.min_ground_clearance()
## and Terrain.last_carve_clearance are clearances - the smallest gap between
## where this system put mass and the boundary that mass had to respect.
##
## Meaningless with patrol_frames at 0, where it returns the full radius simply
## because nothing was ever sampled. Read the two together.
func patrol_clearance() -> float:
	return patrol_radius - max_patrol_excursion


## Live distance from this tank to its own patrol centre, flat. Derived from the
## TRANSFORM rather than from any of the counters above, so reading it alongside
## max_patrol_excursion is a check rather than a re-execution.
func distance_from_centre() -> float:
	return _flat_distance(global_position, patrol_centre)


## Shells needed to destroy this tank, from the authored profile and the shell's
## reference damage. Read it rather than assuming 1: it is the same division
## Tower.hits_to_kill() and Tank.hits_to_kill() do, and an authored max_health
## that has drifted off Shell.NOMINAL_DAMAGE shows up here as a number that is
## not 1 instead of as a tank that survives a direct hit.
##
## Zero when there is no profile to divide, so "I could not measure this" fails a
## gate rather than passing one as a silent 1.
func hits_to_kill() -> int:
	if damageable == null or damageable.profile == null:
		return 0
	if Shell.NOMINAL_DAMAGE <= 0.0:
		return 0
	return int(round(damageable.profile.max_health / Shell.NOMINAL_DAMAGE))


## Still fighting. False from the moment the hull reaches zero.
func is_alive() -> bool:
	return damageable != null and damageable.is_alive


## The current state as a word, for a log line or a harness read that a person
## has to interpret.
func state_name() -> String:
	if state < 0 or state >= STATE_NAMES.size():
		return "unknown"
	return STATE_NAMES[state]


# ------------------------------------------------------------
# State machine
# ------------------------------------------------------------
func _update_state() -> void:
	if target == null:
		return

	match state:
		State.PATROLLING:
			# `_contained` is the no-chatter guard from the header: a tank that
			# has been leashed has to make it home before it looks for another
			# fight.
			if _contained and can_see(target.global_position):
				_enter(State.ENGAGING)
		State.ENGAGING:
			# DISTANCE IS THE ONLY WAY OUT. Not losing sight - see the header.
			if should_leash(target.global_position):
				_enter(State.PATROLLING)


func _enter(next: int) -> void:
	if next == state:
		return
	state = next

	if next == State.ENGAGING:
		aggro_transitions += 1
		# Out of the circle now, and not eligible to re-acquire until it is back
		# inside one - which _track_patrol is what decides.
		_contained = false
	else:
		leash_transitions += 1
		# Head straight home rather than to whatever waypoint was current when
		# the chase started; the containment steering would override it anyway,
		# and this keeps the waypoint timer honest.
		_waypoint = patrol_centre
		_waypoint_age = 0.0

	GameLogger.write_log("state", "enemy_state", {
		"enemy": name,
		"state": state_name(),
		"distance_from_centre": snappedf(distance_from_centre(), 0.01),
		"aggro_transitions": aggro_transitions,
		"leash_transitions": leash_transitions,
	})


# ------------------------------------------------------------
# Steering and drive
# ------------------------------------------------------------
# Where this tank is trying to get to this frame.
func _steer_target(delta: float) -> Vector3:
	if state == State.ENGAGING and target != null:
		return target.global_position

	_waypoint_age += delta
	if _flat_distance(global_position, _waypoint) < WAYPOINT_ARRIVAL \
			or _waypoint_age > WAYPOINT_TIMEOUT:
		_pick_waypoint()

	# Outside the inner ring, home is the only destination that matters. This is
	# also the whole of "go home" after a leash: the tank is a long way outside
	# the ring, so this branch already points it at the centre.
	if distance_from_centre() > patrol_radius * CONTAINMENT_FRACTION:
		return patrol_centre

	return _waypoint


# The player's _drive() with the input replaced by a heading, and the same four
# forces in the same order: steer, thrust, gravity, quadratic drag. The numbers
# are Tank's constants, so the two chassis coast and turn identically.
func _drive(point: Vector3, delta: float) -> void:
	var to := point - global_position
	to.y = 0.0

	var throttle := 0.0
	if to.length_squared() > 0.0001:
		# -Z is forward in Godot, so the yaw whose forward points along `to` is
		# atan2(-x, -z) rather than atan2(x, z). Getting this wrong drives every
		# tank exactly backwards, which looks like a steering bug rather than a
		# sign error.
		var desired := atan2(-to.x, -to.z)
		var error := wrapf(desired - rotation.y, -PI, PI)

		# Steering authority falls off with speed, exactly as the player's does,
		# so a red tank cannot pivot on the spot at full throttle either.
		var steer_scale := 1.0 / (1.0 + speed * 0.02)
		var max_step := deg_to_rad(TURN_RATE) * steer_scale * delta
		rotation.y += clampf(error, -max_step, max_step)

		# Throttle by how well the nose is already lined up: full ahead when
		# pointed at the target, nothing at all when it is off the beam. Without
		# this the tank drives a wide arc past everything it aims at.
		throttle = maxf(cos(error), 0.0)

	if throttle > 0.0:
		velocity += -basis.z * FORWARD_DRIVE * throttle * delta

	if not is_on_floor():
		velocity.y += gravity * delta

	var horizontal := Vector3(velocity.x, 0.0, velocity.z)
	var horizontal_speed := horizontal.length()
	if horizontal_speed > 0.01:
		velocity += -horizontal.normalized() * horizontal_speed * horizontal_speed \
			* DRAG_COEFF * delta

	# Kills the residual creep that leaves a tank sliding for ever on flat
	# ground.
	if is_on_floor() and horizontal_speed < 0.6:
		velocity.x *= 0.8
		velocity.z *= 0.8

	if state == State.PATROLLING:
		_apply_patrol_fence(delta)

	move_and_slide()
	speed = Vector3(velocity.x, 0.0, velocity.z).length()


# THE FENCE. Steering aims at 0.7 of the radius and turns for home at 0.85, but
# a tank with momentum on a downhill can still be carried across the line, and
# "usually inside" is not a containment rule - it is a hope with a good average.
#
# So: if the step about to be taken would end outside the circle, the OUTWARD
# radial part of the velocity is removed first. Inward and tangential motion is
# untouched, which is why this reads as a tank turning along the edge of its
# patch rather than as one hitting an invisible wall.
#
# IT DOES FIRE ON A TANK WALKING HOME FROM OUTSIDE, AND AN EARLIER VERSION OF
# THIS COMMENT SAID IT DID NOT. The claim was that a homebound tank's radial
# velocity is negative and so nothing is removed. That is true only once the tank
# has finished TURNING: displaced outside its circle facing the wrong way, it
# carries its old outward velocity through the whole turn, and the fence cancels
# it on every frame of that turn - measured at 33 firings in one such turn. The
# outcome is the one wanted either way, and patrol_fence_stops is the number that
# says so, which is why this is a correction to the comment and not to the code.
#
# A velocity change rather than a position clamp, deliberately: clamping the
# transform after the fact is a teleport, and a teleport would make
# max_patrol_excursion measure the clamp instead of the driving.
func _apply_patrol_fence(delta: float) -> void:
	var offset := Vector2(global_position.x - patrol_centre.x,
		global_position.z - patrol_centre.z)
	if offset.length() < 0.001:
		return

	var flat_velocity := Vector2(velocity.x, velocity.z)
	if (offset + flat_velocity * delta).length() <= patrol_radius:
		return

	var outward := offset.normalized()
	var radial := flat_velocity.dot(outward)
	if radial <= 0.0:
		return

	velocity.x -= outward.x * radial
	velocity.z -= outward.y * radial
	patrol_fence_stops += 1


# A point drawn uniformly inside WAYPOINT_FRACTION of the circle. sqrt() on the
# radius is what makes it uniform by AREA - without it every waypoint clusters
# near the centre and the tank paces the middle of its patch.
func _pick_waypoint() -> void:
	var angle := _rng.randf_range(-PI, PI)
	var radius := sqrt(_rng.randf()) * patrol_radius * WAYPOINT_FRACTION
	_waypoint = patrol_centre + Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
	_waypoint_age = 0.0


# ------------------------------------------------------------
# Bookkeeping
# ------------------------------------------------------------
# THE CENTRE IS CAPTURED ON THE FIRST PHYSICS FRAME, NOT IN _ready(), and that
# is not a style choice. Spawner._place() calls add_child() BEFORE it assigns
# global_position (CollisionLayers' header spells this out), so _ready() runs
# with this tank still at the spawner's origin. A centre captured there would put
# every patrol circle on top of the player's spawn, and every distance in this
# file would be measured from the wrong place while looking perfectly healthy.
func _capture_centre() -> void:
	patrol_centre = global_position
	_centre_captured = true
	_pick_waypoint()


# Records where this tank actually ended up, after the move rather than before -
# the claim being measured is about the position it reached, not the one it
# aimed at.
#
# `_contained` IS WHAT KEEPS THE STATISTIC HONEST IN BOTH DIRECTIONS. A tank that
# has just been leashed is legitimately far outside its circle and walking home;
# counting those frames would report a 300-unit excursion as a containment
# failure. Counting them only AFTER it has got back inside means the number says
# what it claims to say - "once home, it never left again" - and `patrol_frames`
# is published beside it so a statistic that sampled nothing cannot masquerade as
# a tank that never strayed.
func _track_patrol() -> void:
	if state != State.PATROLLING:
		return

	var distance := distance_from_centre()

	if not _contained:
		if distance > patrol_radius:
			return
		_contained = true

	max_patrol_excursion = maxf(max_patrol_excursion, distance)
	patrol_frames += 1


# Distance in the XZ plane, the same measure Spawner uses for separation and for
# the same reason: a patrol patch is a footprint on the ground.
func _flat_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()
