extends CanvasLayer
class_name TankUI

# Heads-up display. Reads the tank rather than being pushed to, because
# everything on it is a continuous quantity - speed, reload, crater count - and
# a signal per change would be a signal per frame.
#
# CanvasLayer rather than the parent project's Node2D: a Node2D HUD is laid out
# in raw pixels against one window size, and every offset in it has to be
# retuned when the window changes. Control anchors inside a CanvasLayer scale
# themselves.

@onready var speed_label: Label = $Root/Readout/Speed
@onready var craters_label: Label = $Root/Readout/Craters
@onready var reload_bar: ColorRect = $Root/ReloadFrame/ReloadFill
@onready var reload_frame: ColorRect = $Root/ReloadFrame
@onready var health_bar: ColorRect = $Root/HealthFrame/HealthFill
@onready var health_frame: ColorRect = $Root/HealthFrame
@onready var help_label: RichTextLabel = $Root/Help
@onready var crosshair: Control = $Root/Crosshair

## Set by the level. Not an @onready node path: the UI must not care where the
## tank sits in the tree, and a wrong path here is a crash on a HUD.
var tank: Tank
var terrain: TerrainSurface

var _frame_width: float = 0.0
var _health_frame_width: float = 0.0
var _help_timer: Timer


## Width in pixels the health fill is drawn at.
##
## COMPUTED ON READ, NOT MIRRORED PER FRAME, for the reason main.gd:62 sets out:
## no frame runs inside a --harness-eval batch, so a var refreshed in _process()
## reports its PRE-BATCH width to anything that damaged the tank in the same
## batch - "the bar never moved" about a bar that did. A getter cannot be stale
## and costs nothing when nobody asks.
##
## It is also the value to read INSTEAD of the ColorRect's pixels or its colour:
## those are what _process() writes from here, so reading them back would be a
## re-execution rather than a check (CLAUDE.md, Traps). Check it against
## Damageable.health, which is derived differently.
var health_bar_width: float:
	get:
		return _health_frame_width * player_health_fraction()


func _ready() -> void:
	_frame_width = reload_frame.size.x
	_health_frame_width = health_frame.size.x

	# The controls stay up for the opening moments and then get out of the way.
	# Long enough to read, short enough not to sit over the first fight.
	_help_timer = Timer.new()
	_help_timer.wait_time = 14.0
	_help_timer.one_shot = true
	_help_timer.timeout.connect(func() -> void: help_label.visible = false)
	add_child(_help_timer)
	_help_timer.start()


## The player's health as 0.0-1.0, straight off the component that owns it.
##
## 0.0 when there is no tank or no Damageable to ask. An empty bar for a player
## who cannot be measured, rather than a full one: a HUD that defaults to healthy
## hides exactly the wiring failure it would be reporting.
func player_health_fraction() -> float:
	if tank == null or tank.damageable == null:
		return 0.0
	return tank.damageable.health_fraction()


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_help"):
		_help_timer.stop()
		help_label.visible = not help_label.visible


func _process(_delta: float) -> void:
	if tank == null:
		return

	speed_label.text = "%3.0f m/s" % tank.speed

	var fraction := tank.reload_fraction()
	reload_bar.size.x = _frame_width * fraction
	# Colour carries the same information as the width, because the bar is in
	# peripheral vision while the player is looking at the crosshair.
	reload_bar.color = Color(0.1, 0.95, 0.75) if fraction >= 1.0 else Color(0.95, 0.35, 0.15)

	# The crosshair goes hot the moment the gun is loaded. This is the only
	# readout the player is actually looking at when it matters.
	crosshair.modulate = Color(1, 1, 1, 1) if fraction >= 1.0 else Color(1, 1, 1, 0.35)

	# Health, drawn from the getter above rather than recomputed here, so there
	# is exactly one expression that turns hit points into pixels.
	var health := player_health_fraction()
	health_bar.size.x = health_bar_width
	health_bar.color = Color(0.95, 0.2, 0.15).lerp(Color(0.15, 0.95, 0.45), health)

	# The crater count is only information while the ground can actually be cut.
	# The clipmap terrain cannot be cut at all and the voxel one has destruction
	# switched off, so this is dead text pinned at 0 either way - the readout
	# drops it and keeps the triangle count, which still describes the world.
	if terrain != null:
		if terrain.is_destructible():
			craters_label.text = "%d craters   %d tris" % [terrain.crater_count(), terrain.triangle_count()]
		else:
			craters_label.text = "%d tris" % terrain.triangle_count()
