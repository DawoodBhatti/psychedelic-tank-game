extends Node

# Autoloaded performance sampler. Writes one "perf"/"fps_sample" line per
# interval, and does nothing at all until the active scene says it has finished
# loading.
#
# The gate is the whole point. This project meshes every terrain chunk with
# marching cubes on the CPU during startup, so the
# first second of any run is dominated by construction cost. Sampling through
# that would fill the log with numbers that describe loading rather than
# gameplay, and those are exactly the numbers that would poison an average.
#
# A Timer rather than counting in _process: the interval should be one second
# of wall clock regardless of how the frame rate is behaving, which is
# especially true when the thing being measured IS a bad frame rate.

## Seconds between samples.
@export var sample_interval: float = 1.0

## Set false to stop sampling without unregistering the autoload.
@export var enabled: bool = true

## Most recent samples, oldest first, so a caller can read what was measured
## rather than re-deriving it from the log. Bounded because this autoload lives
## for the whole session and an unbounded array would grow without limit during
## normal play. --harness-fps reads this.
var samples: Array[Dictionary] = []

## Two minutes of history at the default one-second cadence. Enough for any
## measurement the harness takes, small enough to ignore.
const MAX_RETAINED_SAMPLES := 120

var _timer: Timer
var _scene_name: String = ""
var _samples_taken: int = 0

# The gate stops sampling DURING loading, but not the first measurement's
# WINDOW from overlapping it: TIME_FPS is a trailing one-second average, so a
# sample taken one second after loading_complete still partly describes the
# construction spike. Measured in the project this came from it reported 11 fps
# against a real 120. The first tick is therefore discarded, which costs one
# second of data and removes an outlier that would otherwise wreck any average
# taken over a short run.
var _warmup_done: bool = false


func _ready() -> void:
	# Keep sampling across pauses: a pause is a legitimate thing to measure,
	# and stopping would leave a silent gap that reads like a hang.
	process_mode = Node.PROCESS_MODE_ALWAYS

	_timer = Timer.new()
	_timer.wait_time = sample_interval
	_timer.autostart = false
	_timer.one_shot = false
	_timer.process_mode = Node.PROCESS_MODE_ALWAYS
	_timer.timeout.connect(_on_sample_due)
	add_child(_timer)

	GameEvents.loading_complete.connect(_on_loading_complete)


func _on_loading_complete(scene_name: String) -> void:
	_scene_name = scene_name
	_samples_taken = 0
	_warmup_done = false
	samples.clear()

	if not enabled:
		return

	# start() rather than a guard on "already running": a second scene raising
	# loading_complete should restart the cadence cleanly, not stack timers.
	_timer.wait_time = sample_interval
	_timer.start()


func _on_sample_due() -> void:
	if not enabled:
		return

	# Discard the first tick; see _warmup_done.
	if not _warmup_done:
		_warmup_done = true
		return

	# TIME_FPS is frames completed over the last second, so it is already an
	# average - no smoothing needed on top at a one-second cadence.
	var fps := Performance.get_monitor(Performance.TIME_FPS)
	# Seconds; converted to ms because a frame budget is easier to read that
	# way (16.7 for 60Hz) and it is the number that says WHY fps moved.
	var frame_msec := Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0

	_samples_taken += 1

	var sample := {
		"fps": fps,
		"frame_msec": snappedf(frame_msec, 0.01),
		"scene": _scene_name,
		"n": _samples_taken,
	}

	GameLogger.write_log("perf", "fps_sample", sample)

	samples.append(sample)
	if samples.size() > MAX_RETAINED_SAMPLES:
		samples.pop_front()


## Stops sampling. Resumes on the next loading_complete.
func stop() -> void:
	_timer.stop()
