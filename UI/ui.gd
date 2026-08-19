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
@onready var help_label: RichTextLabel = $Root/Help
@onready var crosshair: Control = $Root/Crosshair

## Set by the level. Not an @onready node path: the UI must not care where the
## tank sits in the tree, and a wrong path here is a crash on a HUD.
var tank: Tank
var terrain: Terrain

var _frame_width: float = 0.0
var _help_timer: Timer


func _ready() -> void:
	_frame_width = reload_frame.size.x

	# The controls stay up for the opening moments and then get out of the way.
	# Long enough to read, short enough not to sit over the first fight.
	_help_timer = Timer.new()
	_help_timer.wait_time = 14.0
	_help_timer.one_shot = true
	_help_timer.timeout.connect(func() -> void: help_label.visible = false)
	add_child(_help_timer)
	_help_timer.start()


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

	if terrain != null:
		craters_label.text = "%d craters   %d tris" % [terrain.craters_carved, terrain.triangles_total]
