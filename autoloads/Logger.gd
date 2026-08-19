extends Node

# Autoloaded structured logger. One NDJSON object per line, one file per launch.
#
# NDJSON (one complete JSON object per line, no enclosing array) is chosen so
# the file is valid and parseable even if the process dies mid-session - the
# last line may be torn, every line before it still reads. That matters more
# than tidiness for a crash log.
#
# Registered first in the autoload list so every other autoload can log from
# its own _ready().
#
# The autoload is named GameLogger, NOT Logger: Godot 4.4+ ships a built-in
# Logger class, and the engine class wins name resolution, so `Logger.write_log`
# resolves to the native type and fails to parse with "Static function
# write_log() not found in base GDScriptNativeClass". The file keeps its
# Logger.gd name; only the singleton is GameLogger, which also lines up with
# GameEvents.

## Log types. Anything outside this set is still written, but is flagged, so a
## typo shows up in the log rather than silently creating a new category.
const TYPES := ["state", "perf", "error", "test"]

const LOG_DIR := "user://logs"

## Stamped once at startup and reused for the whole session, so every line of a
## run lands in the same file.
var _session_stamp: String = ""
var _log_path: String = ""

var _file: FileAccess
## Monotonic reference for the "t" field. Taken as early as possible so the
## first entries read close to zero.
var _start_msec: int = 0


func _ready() -> void:
	# Keep logging alive through scene changes and while the tree is paused.
	process_mode = Node.PROCESS_MODE_ALWAYS

	_start_msec = Time.get_ticks_msec()
	_session_stamp = _make_session_stamp()
	_log_path = "%s/session_%s.log" % [LOG_DIR, _session_stamp]

	DirAccess.make_dir_recursive_absolute(LOG_DIR)

	# WRITE, not READ_WRITE: every launch starts a fresh file rather than
	# appending to a previous run.
	_file = FileAccess.open(_log_path, FileAccess.WRITE)
	if _file == null:
		push_error("Logger: could not open %s (%s)"
			% [_log_path, error_string(FileAccess.get_open_error())])
		return

	write_log("state", "session_start", {
		"path": ProjectSettings.globalize_path(_log_path),
		"godot": Engine.get_version_info().get("string", ""),
		"project": ProjectSettings.get_setting("application/config/name", ""),
	})


func _exit_tree() -> void:
	if _file != null:
		write_log("state", "session_end", {})
		_file.close()
		_file = null


## Writes one line. `type` should be one of TYPES; `event` is a short
## machine-readable name; `data` is anything else worth keeping.
##
## Deliberately not named `log`: that collides with GDScript's built-in log()
## (natural logarithm), and the collision is worse than a shadowed name usually
## is - an unqualified log("state", ...) inside this script resolves to the
## built-in and fails to PARSE, so every internal call would have needed a
## self. prefix to work at all.
func write_log(type: String, event: String, data: Dictionary = {}) -> void:
	if _file == null:
		return

	if not TYPES.has(type):
		# Recorded rather than dropped: a mistyped type should be visible in
		# the log, not invisible.
		data = data.duplicate()
		data["_unknown_type"] = type

	var line := {
		"t": snappedf((Time.get_ticks_msec() - _start_msec) / 1000.0, 0.001),
		"type": type,
		"event": event,
		"data": data,
	}

	_file.store_line(JSON.stringify(line))
	# Flushed per line so a crash still leaves everything up to the crash on
	# disk. These volumes are tiny; the safety is worth the syscall.
	_file.flush()


## Absolute path of this session's file, for showing the user where it went.
func get_log_path() -> String:
	return ProjectSettings.globalize_path(_log_path)


# Sortable, filename-safe, and unique per launch. Colons are illegal in Windows
# filenames so the time separators are stripped, and a millisecond suffix keeps
# two launches in the same second from colliding.
func _make_session_stamp() -> String:
	var now := Time.get_datetime_dict_from_system()
	return "%04d%02d%02d_%02d%02d%02d_%03d" % [
		now.year, now.month, now.day,
		now.hour, now.minute, now.second,
		Time.get_ticks_msec() % 1000,
	]


## Convenience for deliberate error/warning sites.
##
## These deliberately go through push_error/push_warning rather than writing a
## line directly: that keeps ONE capture path (ErrorCapture tails Godot's own
## log), so a hand-written error and an engine one arrive in the same shape,
## with the same source location and backtrace. Writing here as well would
## duplicate every record.
func error(message: String) -> void:
	push_error(message)


func warn(message: String) -> void:
	push_warning(message)
