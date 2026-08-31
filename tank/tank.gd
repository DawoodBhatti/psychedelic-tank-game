extends CharacterBody3D
class_name Tank

# The player's tank: a hull that drives, and a turret that aims independently
# of wherever the hull happens to be pointing.
#
# That independence is the whole feel of the thing, and it is why the turret's
# yaw is tracked in WORLD space rather than as a local rotation. Aim at a
# target, then steer: the hull swings underneath and the gun stays on the
# target. Storing a local angle would rotate the gun with the hull and make
# aiming while turning impossible.
#
# PHYSICS IS UPRIGHT; TILT IS COSMETIC. The body only ever yaws - it never
# pitches or rolls - and the visible lean over a slope is applied to the hull
# MESH instead. Rotating a CharacterBody3D to match a ground normal changes the
# basis its own movement is expressed in, so the tank starts driving into the
# hill it is climbing and the input direction stops meaning what it says. This
# split costs one node and removes that entire class of bug.

# ============================================================
# Nodes
# ============================================================
@onready var hull_pivot: Node3D = $HullPivot
@onready var turret: Node3D = $Turret
@onready var barrel: Node3D = $Turret/Barrel
@onready var muzzle: Marker3D = $Turret/Barrel/Muzzle
@onready var camera_arm: SpringArm3D = $Turret/CameraArm
@onready var ground_probe: RayCast3D = $GroundProbe

## Hit points. Its DamageProfile is entities/profiles/player_tank.tres, authored
## at 3 x Shell.NOMINAL_DAMAGE - see hits_to_kill(), which divides rather than
## repeating the 3.
##
## A CHILD COMPONENT, NOT FIELDS ON THIS SCRIPT, and that is Damageable's whole
## argument: the tower is a StaticBody3D and this is a CharacterBody3D, and they
## get identical hit points out of one file and two .tres.
@onready var damageable: Damageable = $Damageable

# ============================================================
# Drive
# ============================================================
## Forward acceleration in m/s^2. Read by the harness through the script
## constant map, which is why these are consts rather than exports.
const FORWARD_DRIVE := 26.0
const REVERSE_DRIVE := 14.0

## Multiplier applied to drive while boost is held.
const BOOST_MULTIPLIER := 2.6

## Degrees per second the hull turns. Halved at speed so the tank cannot pivot
## on the spot while travelling, which is what makes it feel heavy.
const TURN_RATE := 95.0

## Terminal speed under normal drive, before boost. Enforced by drag rather
## than a clamp so acceleration tails off instead of stopping dead.
const DRAG_COEFF := 0.055

## Extra drag while the handbrake is held.
const BRAKE_DRAG := 0.9

@export var gravity: float = -26.0

## How fast the cosmetic hull tilt catches up with the ground normal. Low
## enough to read as suspension, high enough not to lag a jump.
@export var tilt_response: float = 6.0

# ============================================================
# Gunnery
# ============================================================
@export var shell_scene: PackedScene = preload("res://tank/shell.tscn")

## Seconds between shots.
@export var reload_time: float = 1.1

## Muzzle velocity in m/s. Shells are raycast rather than swept by the physics
## engine, so this can be high without tunnelling through the terrain.
@export var muzzle_velocity: float = 95.0

## Recoil impulse pushed back into the hull on firing, in m/s.
@export var recoil: float = 2.0

# ============================================================
# Aim
# ============================================================
const LOOK_SENSITIVITY := 0.25       # degrees per pixel of mouse movement
const LOOK_SPEED := 130.0            # controller degrees per second
const PITCH_MIN := -12.0             # the gun can only depress a little
const PITCH_MAX := 42.0

# ------------------------------------------------------------
# Camera coupling
# ------------------------------------------------------------
# TWO CONSTANTS, TWO JOBS, AND THEY ARE NOT INTERCHANGEABLE. The camera's
# HEIGHT is the arm's pivot - Turret y 1.3 + CameraArm y 4.2 = 5.5 above the
# hull origin, in tank.tscn, which is the only place it is set. The camera's
# PITCH is what follows the gun, and that is these two numbers and nothing
# else.
#
# They were tangled once. The pre-S1 line was `-barrel_pitch * 0.6 - 10`, where
# the -10 was silently buying height: the arm holds the camera 13 units out
# along its local +Z, so an arm pitched down lifts the camera by
# -13 * sin(pitch) and a large negative bias reads as "higher". Un-inverting the
# sign therefore dropped the resting camera from ~6.0 to 2.75 without anyone
# touching a height. Height goes in the pivot; pitch goes here.

## How much of the gun's elevation the camera follows. Under 1.0 so the view
## swings gentler than the gun does.
const CAMERA_PITCH_FOLLOW := 0.6

## Degrees the resting view sits below the gun's line. Trim for FRAMING only -
## it is not the height dial, and using it as one is the bug described above.
const CAMERA_PITCH_BIAS := -5.0

# ============================================================
# State
# ============================================================
## Where the tank starts and returns to. Set by the level, which is the only
## thing that knows where the ground is.
@export var spawn_position: Vector3 = Vector3(0, 30, 0)

## Falling below this resets the run, so driving into a crater you cannot climb
## out of can never strand you.
@export var death_height: float = -60.0

## Seconds between the hull being destroyed and the level being put back.
##
## THE FALL HAS NO DELAY AND THIS ONE DOES, and the difference is what there is
## to see. Below death_height the tank is under the world and the camera is
## looking at nothing, so waiting buys the player a second of black; a hull shot
## out from under him happens where he is looking, and a reset on the same frame
## as the killing hit reads as a teleport rather than as a death.
##
## Both still go out as level_reset_requested - one path, one handler in main.gd.
@export var death_reset_delay: float = 1.6

## Turret heading in WORLD space, degrees. See the class comment.
var turret_yaw: float = 0.0

## Gun elevation, degrees. Shared by the barrel and the camera arm, so the
## camera always looks where the shell will go.
var barrel_pitch: float = 8.0

var alive: bool = true
var reload_remaining: float = 0.0
var shells_fired: int = 0

## Current speed in m/s. Harness-facing, and what the UI reads.
var speed: float = 0.0

var _was_boosting: bool = false


func _ready() -> void:
	global_position = spawn_position
	turret_yaw = rotation_degrees.y
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

	# The plan's mask table for the player tank, transcribed rather than
	# re-derived: layer PLAYER, masking TERRAIN and ENEMIES. Named bits because
	# the editor numbers layers from 1 and code shifts from bit 0, and every
	# place those two schemes meet is a chance to be off by one.
	#
	# ENEMIES was added when guardians got a layer of their own. Without it the
	# tank drives straight through a guardian hull - which is not a crash, not a
	# warning and not visible in any headless test. It stays through S2's cull of
	# the guardians: S4c puts enemy tanks back on that bit.
	#
	# STRUCTURES joined it in S4 for exactly the same reason and with exactly the
	# same failure mode. A tower is a StaticBody3D nothing masks, which is
	# scenery drawn where the tank can drive through it - and the shell would
	# still detonate on it, so the tower would crack while the hull passed
	# straight out the other side.
	#
	# Shells are still not masked here: they are on the reserved PLAYER_SHELLS
	# bit, carry no body at all, and must pass through the tank that fired them.
	#
	# THIS IS THE ONLY PLACE THE TANK'S LAYERS ARE SET. tank.tscn used to carry
	# the same two values, which meant two places to disagree and this one
	# silently winning. See CollisionLayers' header.
	collision_layer = CollisionLayers.PLAYER
	collision_mask = CollisionLayers.TERRAIN | CollisionLayers.ENEMIES \
		| CollisionLayers.STRUCTURES

	if damageable == null:
		push_error("Tank %s: no Damageable child - it cannot be destroyed" % name)
	else:
		damageable.destroyed.connect(_on_destroyed)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_apply_aim(event.relative.x * LOOK_SENSITIVITY, event.relative.y * LOOK_SENSITIVITY)
	elif event.is_action_pressed("ui_cancel"):
		# Release the mouse rather than quitting: quitting on Escape makes the
		# game impossible to alt-tab out of cleanly during a review.
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	elif event is InputEventMouseButton and event.pressed:
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func _process(delta: float) -> void:
	var aim_x := Input.get_action_strength("aim_right") - Input.get_action_strength("aim_left")
	var aim_y := Input.get_action_strength("aim_down") - Input.get_action_strength("aim_up")
	if aim_x != 0.0 or aim_y != 0.0:
		_apply_aim(aim_x * LOOK_SPEED * delta, aim_y * LOOK_SPEED * delta)


func _apply_aim(dx: float, dy: float) -> void:
	turret_yaw = wrapf(turret_yaw - dx, -180.0, 180.0)
	barrel_pitch = clampf(barrel_pitch - dy, PITCH_MIN, PITCH_MAX)


func _physics_process(delta: float) -> void:
	if Input.is_action_just_pressed("respawn"):
		GameEvents.level_reset_requested.emit("manual")

	if alive and global_position.y < death_height:
		alive = false
		GameEvents.level_reset_requested.emit("fell")
		return

	if not alive:
		# Destroyed, and waiting out death_reset_delay. The wreck keeps its
		# collision and its transform and simply stops taking orders - without
		# this it would still drive, still tilt and still reload while dead, and
		# the only thing saying otherwise would be a flag nothing reads.
		return

	_drive(delta)
	_aim(delta)
	_gunnery(delta)


# ------------------------------------------------------------
# Drive
# ------------------------------------------------------------
func _drive(delta: float) -> void:
	var throttle := Input.get_action_strength("drive_forward") - Input.get_action_strength("drive_back")
	var steer := Input.get_action_strength("steer_right") - Input.get_action_strength("steer_left")
	var boosting := Input.is_action_pressed("boost") and throttle > 0.0
	var braking := Input.is_action_pressed("handbrake")

	# Steering authority falls off with speed. Without this the tank spins on
	# the spot at full throttle, which reads as a hovercraft.
	var steer_scale := 1.0 / (1.0 + speed * 0.02)
	rotation_degrees.y -= steer * TURN_RATE * steer_scale * delta

	if throttle != 0.0 and not braking:
		var drive: float = FORWARD_DRIVE if throttle > 0.0 else REVERSE_DRIVE
		if boosting:
			drive *= BOOST_MULTIPLIER
		# -Z is forward in Godot. `basis` rather than `transform.basis` for the
		# same reason: it is the body's current orientation, which steering has
		# already updated this frame.
		velocity += -basis.z * drive * signf(throttle) * delta

	if not is_on_floor():
		velocity.y += gravity * delta

	# Quadratic drag, so top speed emerges from the drive/drag balance rather
	# than a hard clamp. Braking simply raises the coefficient.
	var horizontal := Vector3(velocity.x, 0.0, velocity.z)
	var horizontal_speed := horizontal.length()
	if horizontal_speed > 0.01:
		var coeff: float = BRAKE_DRAG if braking else DRAG_COEFF
		var drag := -horizontal.normalized() * horizontal_speed * horizontal_speed * coeff
		velocity += drag * delta

	# Kills the residual creep that leaves the tank sliding for ever on a flat
	# chunk face.
	if is_on_floor() and horizontal_speed < 0.6:
		velocity.x *= 0.8
		velocity.z *= 0.8

	if alive:
		move_and_slide()

	speed = Vector3(velocity.x, 0.0, velocity.z).length()

	_set_boosting(boosting)
	_tilt_hull(delta)


# Cosmetic only. See the class comment for why this is not the body's rotation.
func _tilt_hull(delta: float) -> void:
	var normal := Vector3.UP
	if is_on_floor():
		normal = get_floor_normal()
	elif ground_probe.is_colliding():
		normal = ground_probe.get_collision_normal()

	# Build a basis whose up is the ground normal but whose forward still
	# matches the hull's heading, then take only the pitch and roll from it -
	# the yaw is the body's and must not be applied twice.
	var forward := -basis.z
	var right := forward.cross(normal).normalized()
	if right.length_squared() < 0.0001:
		return
	var aligned_forward := normal.cross(right).normalized()
	var target := Basis(right, normal, -aligned_forward)

	var local_target := basis.inverse() * target
	hull_pivot.basis = hull_pivot.basis.slerp(local_target.orthonormalized(),
		clampf(tilt_response * delta, 0.0, 1.0))


# ------------------------------------------------------------
# Aim
# ------------------------------------------------------------
func _aim(_delta: float) -> void:
	# turret_yaw is a world heading, so the hull's own yaw is subtracted out.
	# This is the line that makes the turret hold its target while the hull
	# turns underneath it.
	turret.rotation_degrees.y = turret_yaw - rotation_degrees.y
	barrel.rotation_degrees.x = barrel_pitch
	# The camera shares the gun's elevation, and shares its SIGN. The arm holds
	# the camera along its local +Z while the camera looks along local -Z, so
	# the camera's forward Y is sin(arm pitch): a POSITIVE arm pitch is a camera
	# that looks up.
	#
	# This used to be negated, which is what read as inverted vertical aim. The
	# gun was always right - _apply_aim() subtracts dy, and mouse-up is a
	# negative relative.y, so mouse-up raises barrel_pitch and a positive X
	# rotation on the barrel points the gun up. It was the camera that pitched
	# the other way: raising the gun drove the arm further negative, so the
	# camera looked further DOWN and the horizon climbed the screen while the
	# gun climbed with it. Do NOT "fix" this by flipping the sign in
	# _apply_aim(): that depresses the gun on mouse-up, which is the opposite of
	# what was asked, and every automated test still passes.
	#
	# PITCH ONLY. Height is the pivot's y in tank.tscn - see the note on
	# CAMERA_PITCH_FOLLOW / CAMERA_PITCH_BIAS. The arm masks layer 1, so at full
	# elevation it pulls in against the terrain it swings down into rather than
	# clipping through it.
	camera_arm.rotation_degrees.x = barrel_pitch * CAMERA_PITCH_FOLLOW + CAMERA_PITCH_BIAS


# ------------------------------------------------------------
# Gunnery
# ------------------------------------------------------------
func _gunnery(delta: float) -> void:
	reload_remaining = maxf(reload_remaining - delta, 0.0)

	if Input.is_action_pressed("fire") and reload_remaining <= 0.0 and alive:
		fire()


## Fires one shell. Public so the harness can call it on the live node - an
## input binding cannot be tested through --harness-eval, so the branch body
## has to be reachable directly.
func fire() -> void:
	if shell_scene == null:
		push_error("Tank.fire(): no shell_scene assigned.")
		return

	var shell := shell_scene.instantiate()
	# Parented to the level, not to the tank: a shell attached to the turret
	# would inherit every steer and every aim change for its whole flight.
	get_parent().add_child(shell)
	shell.global_position = muzzle.global_position
	shell.launch(-muzzle.global_basis.z * muzzle_velocity)

	reload_remaining = reload_time
	shells_fired += 1

	velocity += muzzle.global_basis.z * recoil

	GameEvents.shell_fired.emit(shell)


## True while the gun is still reloading. What the UI gauge reads.
func is_reloading() -> bool:
	return reload_remaining > 0.0


## 0.0 just fired, 1.0 ready.
func reload_fraction() -> float:
	if reload_time <= 0.0:
		return 1.0
	return clampf(1.0 - reload_remaining / reload_time, 0.0, 1.0)


# ------------------------------------------------------------
# Lifecycle
# ------------------------------------------------------------
## Shells needed to destroy this tank, from the authored profile and the shell's
## reference damage. Read it rather than assuming 3 - it is the same division
## Tower.hits_to_kill() does, and for the same reason: an exported "3" would be a
## third copy of a fact that already exists twice, and the copy is the one that
## goes stale.
##
## Zero when there is no profile to divide, so "I could not measure this" fails a
## gate rather than passing one as a silent 1.
func hits_to_kill() -> int:
	if damageable == null or damageable.profile == null:
		return 0
	if Shell.NOMINAL_DAMAGE <= 0.0:
		return 0
	return int(round(damageable.profile.max_health / Shell.NOMINAL_DAMAGE))


# The hull reached zero. This is the SECOND way to die and it goes out through
# the FIRST one's path: the fall already emits level_reset_requested and main.gd
# already owns what a reset restores, so there is nothing here but a delay and
# the same signal.
#
# `alive` is dropped on this frame rather than when the timer fires, so the wreck
# stops driving immediately and anything asking whether the player is up gets the
# answer the player can see.
func _on_destroyed(_source: Node3D) -> void:
	if not alive:
		return
	alive = false

	GameLogger.write_log("state", "tank_destroyed", {
		"shells_fired": shells_fired,
		"reset_delay": death_reset_delay,
	})

	# Re-checked when it fires: a manual respawn during the delay puts the tank
	# back up, and a second reset landing on top of that would throw away a run
	# the player had already restarted.
	get_tree().create_timer(death_reset_delay).timeout.connect(
		func() -> void:
			if not alive:
				GameEvents.level_reset_requested.emit("destroyed"))


## Puts the tank back at the start. Called by the level, which also puts the
## terrain back - restoring the world is not the tank's business.
func respawn() -> void:
	velocity = Vector3.ZERO
	global_position = spawn_position
	rotation_degrees = Vector3.ZERO
	hull_pivot.basis = Basis.IDENTITY
	turret_yaw = 0.0
	barrel_pitch = 8.0
	reload_remaining = 0.0
	shells_fired = 0
	speed = 0.0
	# Hit points come back with the run. restore() rather than heal(): a heal
	# cannot revive on purpose (see Damageable), and after a third shell this
	# tank is destroyed rather than merely hurt.
	if damageable != null:
		damageable.restore()
	alive = true
	_set_boosting(false)
	GameEvents.tank_respawned.emit()


# Announces boost transitions once rather than every frame it is held, so a
# listener can start and stop a looping effect without tracking state itself.
func _set_boosting(boosting: bool) -> void:
	if boosting == _was_boosting:
		return
	_was_boosting = boosting
	if boosting:
		GameEvents.boost_started.emit()
	else:
		GameEvents.boost_ended.emit()
