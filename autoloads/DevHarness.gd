extends Node

# Autoloaded development harness. Inert during normal play; wakes only when the
# game is launched with a --harness-* argument after a bare `--`.
#
# WHY THIS EXISTS. Checking anything about a running game from outside is
# impossible - no external process can reach into the scene tree to move a
# camera, read a value or fake an input. Only code running inside Godot can do
# that. So every check previously meant writing a throwaway script, registering
# it as an autoload, running, reading the result, unregistering it and deleting
# the file. Six steps per question, done by hand, with a temp autoload left
# registered if anything went wrong in the middle.
#
# This is that hatch, made permanent and inert. It cannot ship by accident
# because without an argument it returns immediately from _ready().
#
# USAGE (note the bare -- separating Godot's own arguments from ours):
#
#   godot --headless -- --harness-check-resources
#   godot --headless -- --harness-eval="scene.chunks_total"
#   godot -- --harness-shot=0,120,120:0,0,0 --harness-out=layout.png
#   godot -- --harness-fps=5 [--harness-fps-min=45]
#
# Results go to stdout as HARNESS: lines (greppable by a caller) AND to the
# session log as "test" entries, and the process exits 0 for pass, 1 for fail.

const ARG_PREFIX := "--harness-"

## Extensions walked by --harness-check-resources.
const CHECKED_EXTS := ["tscn", "tres", "gdshader", "glb", "glsl"]

var _args: Dictionary = {}


func _ready() -> void:
	_args = _parse_args()
	if _args.is_empty():
		# Normal play. Do nothing at all.
		return

	process_mode = Node.PROCESS_MODE_ALWAYS
	_run()


# --harness-foo=bar -> {"foo": ["bar"]}; --harness-foo -> {"foo": [""]}
#
# Values are collected into arrays so a flag can be REPEATED. That matters for
# --harness-eval: every launch costs a full engine boot plus a level rebuild
# (~1.4s here), so asking thirteen questions one at a time cost thirteen boots.
# Repeating the flag answers them all in one.
#
# Reads only user args (everything after a bare --), so Godot's own flags are
# never misread as harness commands.
func _parse_args() -> Dictionary:
	var out := {}
	for arg in OS.get_cmdline_user_args():
		if not arg.begins_with(ARG_PREFIX):
			continue
		var body := arg.substr(ARG_PREFIX.length())
		var eq := body.find("=")
		var key := body if eq == -1 else body.substr(0, eq)
		var value := "" if eq == -1 else body.substr(eq + 1)
		if not out.has(key):
			out[key] = []
		out[key].append(value)
	return out


# First value for a flag, for the ones that only make sense once.
func _arg(key: String, fallback: String = "") -> String:
	if not _args.has(key) or _args[key].is_empty():
		return fallback
	return String(_args[key][0])


func _run() -> void:
	if _args.has("check-resources"):
		await _cmd_check_resources()
	elif _args.has("eval"):
		await _cmd_eval(_args["eval"])
	elif _args.has("shot"):
		await _cmd_shot(_arg("shot"), _arg("out", "harness_shot.png"))
	elif _args.has("fps"):
		await _cmd_fps(_arg("fps", "5"))
	else:
		_report("usage", false, {
			"commands": [
				"check-resources",
				"eval=<expr>  (repeatable - batch several in one launch)",
				"shot=x,y,z:tx,ty,tz [out=path]",
				"fps=<n>  (windowed only - waits for n samples)",
			],
		})


# ---------------------------------------------------------
# Commands
# ---------------------------------------------------------

# Loads every resource in the project and reports the ones that fail.
#
# This is the check that would have caught a broken material reference after a
# folder move: the game still RAN, because the running scene never touched the
# file, so a smoke test said everything was fine while an asset was dead.
func _cmd_check_resources() -> void:
	var failed: Array[String] = []
	var paths := _all_resource_paths()

	for path in paths:
		if ResourceLoader.load(path) == null:
			failed.append(path)

	_report("check_resources", failed.is_empty(), {
		"checked": paths.size(),
		"failed": failed,
	})


# Evaluates a GDScript expression against the live tree, once the scene has
# finished loading. `scene`, `tree` and `root` are available as names.
#
# This is the one that matters most. Most real defects in this pipeline's history
# have been wrong NUMBERS rather than crashes - a light pointing the wrong way,
# an amplitude two orders of magnitude too large, a gap that was meant to stop
# the player and did not. Asking the running game is cheap.
func _cmd_eval(sources: Array) -> void:
	await _await_loaded()

	var inputs := [get_tree().current_scene, get_tree(), get_tree().root]
	var results := []
	var all_ok := true

	for source_variant in sources:
		var source := String(source_variant)
		var expr := Expression.new()

		if expr.parse(source, ["scene", "tree", "root"]) != OK:
			results.append({"expression": source, "error": expr.get_error_text()})
			all_ok = false
			continue

		var value = expr.execute(inputs, self)
		if expr.has_execute_failed():
			results.append({"expression": source, "error": expr.get_error_text()})
			all_ok = false
			continue

		results.append({"expression": source, "value": str(value)})
		# One readable line per expression as well as the structured report, so
		# a batch of answers can be read at a glance without parsing JSON.
		print("HARNESS: eval  %s = %s" % [source, str(value)])

	# A single expression keeps the original flat shape, so anything already
	# parsing "value" out of the report does not break.
	if results.size() == 1:
		_report("eval", all_ok, results[0])
	else:
		_report("eval", all_ok, {"count": results.size(), "results": results})


# Screenshots from an explicit camera pose: "x,y,z:tx,ty,tz".
func _cmd_shot(pose: String, out_path: String) -> void:
	if RenderingServer.get_rendering_device() == null:
		# Headless has no rendering device, so nothing is ever drawn and the
		# capture would be blank. Fail loudly rather than write an empty file
		# that looks like a pass.
		_report("shot", false, {"error": "no rendering device - run without --headless"})
		return

	var halves := pose.split(":")
	if halves.size() != 2:
		_report("shot", false, {"error": "expected x,y,z:tx,ty,tz", "got": pose})
		return

	var from := _parse_vec3(halves[0])
	var to := _parse_vec3(halves[1])

	await _await_loaded()

	var cam := Camera3D.new()
	cam.far = 8000.0
	get_tree().current_scene.add_child(cam)
	cam.global_position = from
	if not from.is_equal_approx(to):
		cam.look_at(to, Vector3.UP)
	cam.current = true

	# Let the frame settle: shaders compile on first use, and the terrain's
	# neon material only looks like itself once its pipeline is built.
	await get_tree().create_timer(0.5).timeout
	await RenderingServer.frame_post_draw

	var image := get_viewport().get_texture().get_image()
	var err := image.save_png(out_path)

	_report("shot", err == OK, {
		"path": ProjectSettings.globalize_path(out_path),
		"from": str(from),
		"to": str(to),
		"error": error_string(err) if err != OK else "",
	})


# Measures frame rate by WAITING for samples, rather than guessing a frame
# budget large enough to contain them.
#
# The documented fps test used to be `--quit-after 300` followed by a grep for
# fps_sample entries, and it could never pass. --quit-after counts FRAMES, while
# PerfSampler runs on a one-second wall-clock Timer and discards its first tick,
# so the first usable sample lands about two seconds after loading_complete. No
# frame count reliably reaches that - at headless frame rates 300 frames is a
# fraction of a second - so every run exited before a single sample existed.
# Zero samples reads like "no data" rather than "broken test", which is exactly
# why it sat unnoticed. Waiting on the sample COUNT removes the guess.
func _cmd_fps(count_arg: String) -> void:
	if RenderingServer.get_rendering_device() == null:
		# Headless draws nothing and compiles no shaders, so any frame rate it
		# reported would describe an idle renderer rather than the game.
		_report("fps", false, {
			"error": "no rendering device - fps under --headless measures nothing; run windowed",
		})
		return

	if not PerfSampler.enabled:
		_report("fps", false, {"error": "PerfSampler.enabled is false - no sample will ever arrive"})
		return

	var want := maxi(1, count_arg.to_int())
	var floor_fps := float(_arg("fps-min", "45"))

	await _await_loaded()

	# The sampler starts on loading_complete and throws its first tick away, so
	# n samples take roughly (n + 1) intervals. The slack absorbs a slow frame
	# and the gap between loading finishing and the timer actually starting.
	var interval: float = PerfSampler.sample_interval
	var budget_s := (float(want) + 2.0) * interval + 5.0
	var deadline := get_tree().create_timer(budget_s)

	while PerfSampler.samples.size() < want and deadline.time_left > 0.0:
		await get_tree().process_frame

	var got := PerfSampler.samples.duplicate()

	if got.is_empty():
		_report("fps", false, {
			"error": "no samples within %.1fs" % budget_s,
			"wanted": want,
		})
		return

	var lo := INF
	var hi := -INF
	var total := 0.0
	for sample in got:
		var f := float(sample["fps"])
		lo = minf(lo, f)
		hi = maxf(hi, f)
		total += f

	# Threshold on the WORST sample, not the average. A mean comfortably over 60
	# can hide a one-second stall, and a stall is the thing worth finding.
	_report("fps", lo >= floor_fps, {
		"samples": got.size(),
		"wanted": want,
		"min": snappedf(lo, 0.01),
		"avg": snappedf(total / float(got.size()), 0.01),
		"max": snappedf(hi, 0.01),
		"min_required": floor_fps,
		"scene": String(got[0].get("scene", "")),
	})


# ---------------------------------------------------------
# Plumbing
# ---------------------------------------------------------

# Waits for the scene to say it has finished building, so a measurement never
# reads a half-constructed tree. Falls back to a short delay for any scene that
# does not raise loading_complete.
func _await_loaded() -> void:
	if get_tree().current_scene != null \
			and "_loading_complete" in get_tree().current_scene \
			and get_tree().current_scene._loading_complete:
		return

	var timeout := get_tree().create_timer(10.0)
	var done := [false]
	var on_loaded := func(_s): done[0] = true
	GameEvents.loading_complete.connect(on_loaded, CONNECT_ONE_SHOT)

	while not done[0] and timeout.time_left > 0.0:
		await get_tree().process_frame

	if GameEvents.loading_complete.is_connected(on_loaded):
		GameEvents.loading_complete.disconnect(on_loaded)


# Every result goes to three places: stdout for a shell caller to grep, the
# session log for anything reading structured output, and the process exit code
# so CI can branch on it without parsing anything at all.
func _report(command: String, passed: bool, data: Dictionary) -> void:
	var payload := data.duplicate()
	payload["command"] = command
	payload["passed"] = passed

	GameLogger.write_log("test", "harness_" + command, payload)

	print("HARNESS: %s %s %s" % [
		command,
		"PASS" if passed else "FAIL",
		JSON.stringify(data),
	])

	get_tree().quit(0 if passed else 1)


func _parse_vec3(s: String) -> Vector3:
	var parts := s.split(",")
	if parts.size() != 3:
		return Vector3.ZERO
	return Vector3(float(parts[0]), float(parts[1]), float(parts[2]))


func _all_resource_paths() -> Array[String]:
	var out: Array[String] = []
	var stack := ["res://"]

	while not stack.is_empty():
		var dir_path: String = stack.pop_back()
		var dir := DirAccess.open(dir_path)
		if dir == null:
			continue

		dir.list_dir_begin()
		var entry := dir.get_next()
		while entry != "":
			# Skips .godot, .git and the like.
			if entry.begins_with("."):
				entry = dir.get_next()
				continue

			var full: String = dir_path.path_join(entry) if dir_path != "res://" \
				else "res://" + entry

			if dir.current_is_dir():
				stack.append(full)
			elif CHECKED_EXTS.has(full.get_extension().to_lower()):
				out.append(full)

			entry = dir.get_next()
		dir.list_dir_end()

	return out
