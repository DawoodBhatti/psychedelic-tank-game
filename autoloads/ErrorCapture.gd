extends Node

# Autoloaded. Forwards engine and script errors into the same NDJSON session
# log as everything else.
#
# WHY THIS SHAPE. GDScript cannot intercept runtime errors directly: there is
# no try/catch, no error hook, and OS.add_logger() is C++/GDExtension only. A
# wrapper around push_error() would only ever catch the calls we remembered to
# route through it, which is precisely the wrong set - the errors worth having
# are the ones nobody anticipated.
#
# What Godot does give us is its own log file, and it is richer than anything
# reachable from script: every ERROR, WARNING and SCRIPT ERROR lands there with
# its source location and, for script errors, a full GDScript backtrace. So
# this tails that file and re-emits matching records as structured lines.
#
# The consequence worth knowing: capture is near-live, not synchronous. An
# error appears in the session log within one poll interval of happening, and
# a hard crash may lose whatever was written in the final fraction of a second.

## Where Godot writes its own log. Read from project settings rather than
## hardcoded, so changing the setting does not silently break capture.
const LOG_PATH_SETTING := "debug/file_logging/log_path"

## Longest first: "USER SCRIPT ERROR:" has to be tested before "SCRIPT ERROR:",
## and both before "ERROR:", or the shorter prefix swallows the longer one.
const SEVERITIES := [
	["USER SCRIPT ERROR:", "script_error"],
	["SCRIPT ERROR:", "script_error"],
	["USER ERROR:", "error"],
	["ERROR:", "error"],
	["USER WARNING:", "warning"],
	["WARNING:", "warning"],
]

@export var enabled: bool = true
@export var poll_interval: float = 0.5
@export var capture_warnings: bool = true
## Stops a per-frame error from writing thousands of lines a second.
@export var max_records_per_poll: int = 40
## Backtrace lines kept per record.
@export var max_stack_lines: int = 24

var _path: String = ""
var _offset: int = 0
## Trailing partial line held back until its newline arrives, so a record is
## never parsed from a half-written line.
var _pending: String = ""

var _kind: String = ""
var _message: String = ""
var _stack: PackedStringArray = PackedStringArray()

var _timer: Timer
var _dropped: int = 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS

	_path = String(ProjectSettings.get_setting(LOG_PATH_SETTING, "user://logs/godot.log"))

	if not FileAccess.file_exists(_path):
		# Not an error worth push_error-ing: doing so would write to the very
		# file we failed to find, and on a misconfigured project that is a
		# tight loop. Record it and stay quiet.
		GameLogger.write_log("state", "error_capture_unavailable", {
			"path": _path,
			"hint": "enable debug/file_logging/enable_file_logging",
		})
		return

	# Godot truncates or rotates its log at startup, so byte 0 is this run.
	# Starting from 0 catches errors raised before this autoload was ready.
	_offset = 0

	_timer = Timer.new()
	_timer.wait_time = poll_interval
	_timer.process_mode = Node.PROCESS_MODE_ALWAYS
	_timer.timeout.connect(_poll)
	add_child(_timer)
	_timer.start()

	GameLogger.write_log("state", "error_capture_started", {"path": _path})


func _exit_tree() -> void:
	# One last sweep so errors in the dying moments are not lost.
	_poll()
	_flush()


func _poll() -> void:
	if not enabled:
		return

	var f := FileAccess.open(_path, FileAccess.READ)
	if f == null:
		return

	var size := f.get_length()
	if size < _offset:
		# File rotated or truncated under us; start over rather than seek past
		# the end and read nothing forever.
		_offset = 0
		_pending = ""
	if size == _offset:
		return

	f.seek(_offset)
	var chunk := f.get_buffer(size - _offset).get_string_from_utf8()
	_offset = size

	var text := _pending + chunk
	var lines := text.split("\n")

	# The final element has no newline yet, so it may be half-written. Hold it
	# until the rest arrives.
	_pending = lines[lines.size() - 1]

	var emitted := 0
	for i in lines.size() - 1:
		if emitted >= max_records_per_poll:
			_dropped += 1
			continue
		if _consume_line(lines[i].strip_edges(false, true)):
			emitted += 1

	if _dropped > 0 and emitted < max_records_per_poll:
		GameLogger.write_log("error", "capture_throttled", {"dropped": _dropped})
		_dropped = 0


# Returns true if this line completed a record.
func _consume_line(line: String) -> bool:
	var severity := _match_severity(line)

	if severity != "":
		# A new record starts, so whatever was being collected is finished.
		var completed := _flush()
		_kind = severity
		_message = line.substr(line.find(":") + 1).strip_edges()
		_stack = PackedStringArray()
		return completed

	if _kind == "":
		return false

	# Continuation lines are indented - "   at: ..." and the numbered GDScript
	# backtrace entries. Anything unindented means the record ended.
	if line.begins_with(" ") or line.begins_with("\t"):
		if _stack.size() < max_stack_lines:
			_stack.append(line.strip_edges())
		return false

	return _flush()


func _match_severity(line: String) -> String:
	for entry in SEVERITIES:
		if line.begins_with(entry[0]):
			return entry[1]
	return ""


# Writes the record being collected, if any. Returns true if it wrote one.
func _flush() -> bool:
	if _kind == "":
		return false

	var kind := _kind
	var message := _message
	var stack := _stack

	_kind = ""
	_message = ""
	_stack = PackedStringArray()

	if kind == "warning" and not capture_warnings:
		return false

	GameLogger.write_log("error", kind, {
		"message": message,
		"stack": stack,
	})
	return true
