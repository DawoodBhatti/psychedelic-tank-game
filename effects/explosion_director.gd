extends Node3D
class_name ExplosionDirector

# The single place that knows what an explosion looks like.
#
# Driven entirely off the GameEvents bus, which means no other script mentions
# explosion visuals at all: the shell does not know it makes a flash, and the
# terrain does not know a hole is accompanied by sparks. Adding, changing or
# muting the effect is a change to this file only.
#
# It listens to `shell_exploded` rather than `terrain_carved` on purpose. The
# carve re-meshes chunks synchronously and can take tens of milliseconds; the
# flash has to be on screen for the frame the bang happened, not the frame
# after the rebuild finished. The two signals exist separately for exactly this
# reason.
#
# Everything is built in code. A particle effect authored as .tres files is
# four more resources for test 2 to walk and four more things to go stale on a
# folder move, for a prototype effect that is twenty lines of setup.

## Peak brightness of the flash light.
@export var flash_energy: float = 14.0

## Seconds the flash takes to fade out.
@export var flash_time: float = 0.35

## Particles per explosion.
@export var spark_count: int = 96

@export var spark_color: Color = Color(1.0, 0.55, 0.1)
@export var flash_color: Color = Color(1.0, 0.75, 0.35)

## Effects live for this many seconds after firing, then free themselves. Must
## comfortably exceed the particle lifetime or sparks are cut off mid-flight.
@export var effect_lifetime: float = 2.5

var _spark_mesh: QuadMesh
var _spark_material: StandardMaterial3D

## Explosions spawned since load. Harness-facing: it is the cheapest way to
## confirm the bus wiring is live without looking at pixels.
var explosions_spawned: int = 0


func _ready() -> void:
	_build_shared_resources()
	GameEvents.shell_exploded.connect(_on_shell_exploded)


# One mesh and one material for every explosion ever spawned. Built once
# because a per-explosion material is a per-explosion shader pipeline, and the
# first frame of a new pipeline is exactly the stall test 4 thresholds on.
func _build_shared_resources() -> void:
	_spark_mesh = QuadMesh.new()
	_spark_mesh.size = Vector2(0.6, 0.6)

	_spark_material = StandardMaterial3D.new()
	_spark_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_spark_material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	# Billboarding disables the vertex-shader path that would otherwise let
	# Godot batch these; keeping particles turned on here is what re-enables it
	# for a particle mesh.
	_spark_material.particles_anim_h_frames = 1
	_spark_material.particles_anim_v_frames = 1
	_spark_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_spark_material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_spark_material.vertex_color_use_as_albedo = true
	_spark_material.albedo_color = spark_color
	_spark_material.emission_enabled = true
	_spark_material.emission = spark_color
	_spark_material.emission_energy_multiplier = 3.0
	_spark_material.disable_receive_shadows = true

	_spark_mesh.material = _spark_material


func _on_shell_exploded(position: Vector3, radius: float) -> void:
	explosions_spawned += 1

	var root := Node3D.new()
	root.name = "Explosion"
	add_child(root)
	root.global_position = position

	root.add_child(_make_sparks(radius))
	var light := _make_flash(radius)
	root.add_child(light)

	# Tween rather than a _process on a throwaway script: one object, no
	# per-frame script call, and it cannot outlive the node it animates.
	var tween := root.create_tween()
	tween.tween_property(light, "light_energy", 0.0, flash_time).from(flash_energy)

	# Freed on a timer rather than on the tween finishing, because the sparks
	# outlast the flash and killing the node at flash_time would cut them off.
	get_tree().create_timer(effect_lifetime).timeout.connect(
		func() -> void:
			if is_instance_valid(root):
				root.queue_free())


func _make_sparks(radius: float) -> GPUParticles3D:
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	process.emission_sphere_radius = radius * 0.25
	process.direction = Vector3(0, 1, 0)
	process.spread = 180.0
	process.initial_velocity_min = radius * 1.2
	process.initial_velocity_max = radius * 3.4
	process.gravity = Vector3(0, -22.0, 0)
	process.scale_min = 0.35
	process.scale_max = 1.4
	process.damping_min = 1.0
	process.damping_max = 4.0
	process.color = spark_color

	var particles := GPUParticles3D.new()
	particles.name = "Sparks"
	particles.amount = spark_count
	particles.lifetime = 1.6
	particles.one_shot = true
	particles.explosiveness = 0.95
	particles.process_material = process
	particles.draw_pass_1 = _spark_mesh
	# Without this the effect is culled the moment its ORIGIN leaves the frame,
	# so an explosion just off screen pops out while its sparks are still
	# flying across the middle of it.
	particles.visibility_aabb = AABB(
		Vector3.ONE * -radius * 4.0, Vector3.ONE * radius * 8.0)
	particles.emitting = true
	return particles


func _make_flash(radius: float) -> OmniLight3D:
	var light := OmniLight3D.new()
	light.name = "Flash"
	light.light_color = flash_color
	light.light_energy = flash_energy
	light.omni_range = radius * 5.0
	# Shadows off: a light that exists for a third of a second does not need
	# them, and a shadow-casting omni is one of the more expensive things that
	# can be spawned mid-frame.
	light.shadow_enabled = false
	return light
