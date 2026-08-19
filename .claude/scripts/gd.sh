#!/usr/bin/env bash
#
# Launch this project's Godot, in ONE command an allow list can approve.
#
# The permission system matches command TEXT. It cannot see through a shell
# variable, a command substitution or a `cd`, and every engine command this
# project ran used all three:
#
#   cd "C:/.../psychedelic-tank-game" && GD="/c/.../Godot_..._console.exe"; \
#     "$GD" --headless -- --harness-eval=... 2>&1 | grep -i HARNESS
#
# Nothing in that line is dangerous and none of it could ever be allowlisted:
# `cd` matches no rule, `GD="..."` differs from the rule by one quote
# character, and `"$GD"` is not resolvable from text at all. So every engine
# command prompted, and fire-and-forget was impossible by construction. The
# fix is not more patterns - it is one stable command, tracked in git and
# reviewable in a diff, that the boilerplate lives inside.
#
# This is the ONLY script permitted to launch the engine, and it launches
# exactly once per invocation. `.claude/hooks/count_godot_launches.py` counts
# invocations of this path, so a test sequence must be several calls to this
# script rather than one script that loops - see the note there.
#
# Usage:
#   .claude/scripts/gd.sh --headless --quit-after 120
#   .claude/scripts/gd.sh --headless -- --harness-eval='scene.chunks_total'
#   .claude/scripts/gd.sh -- --harness-shot=0,26,44:0,2,0 --harness-out=.claude/images/x.png
#   .claude/scripts/gd.sh --raw --headless --import     # unfiltered output
#
# Prints the HARNESS/error lines, then a summary:
#   GD: exit=<code> script_errors=<n> log=<newest session log>
# and exits with the ENGINE's status, not grep's.

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || exit 1
cd "$ROOT" || exit 1

DEFAULT_BIN="/c/Users/dabha/Downloads/Godot_v4.7-stable_mono_win64/Godot_v4.7-stable_mono_win64/Godot_v4.7-stable_mono_win64_console.exe"
BIN="${GODOT_BIN:-$DEFAULT_BIN}"

RAW=0
if [ "${1:-}" = "--raw" ]; then
  RAW=1
  shift
fi

if [ ! -f "$BIN" ]; then
  echo "GD: engine not found at $BIN" >&2
  echo "GD: set GODOT_BIN to override the path." >&2
  exit 127
fi

if [ "$#" -eq 0 ]; then
  echo "GD: no arguments. Pass the Godot arguments you want, e.g." >&2
  echo "GD:   .claude/scripts/gd.sh --headless --quit-after 120" >&2
  exit 2
fi

# Capture rather than pipe, so the exit status is the engine's. A pipeline
# would report grep's status, and "no HARNESS lines matched" is not the same
# fact as "the engine failed" - the harness sets its exit code on purpose.
out="$("$BIN" "$@" 2>&1)"
status=$?

if [ "$RAW" = 1 ]; then
  printf '%s\n' "$out"
else
  printf '%s\n' "$out" | grep -E 'HARNESS:|SCRIPT ERROR|ERROR:|Failed loading' || true
fi

script_errors="$(printf '%s\n' "$out" | grep -c 'SCRIPT ERROR')"
log="$(bash "$ROOT/.claude/scripts/newest-log.sh" path 2>/dev/null)"

# A new `class_name` lives in the global class table in `.godot/`, so no OTHER
# script can resolve it until an import pass registers it: test 1 fails with
# `Could not find type "X"` on a file that is correct. Building a node class
# and instantiating it from tutorial.gd is this project's dominant pattern, so
# this false failure is waiting for most future runs, and its first reading is
# always "my new file is broken".
#
# A hint, NOT an automatic import-and-retry. gd.sh launches the engine exactly
# once per invocation and count_godot_launches.py bills one launch per call to
# this path; a retry inside here would spend three boots and report one, making
# the cost guard under-count in exactly the situation where a run is already
# going badly. The import is a real launch, so the agent spends it knowingly.
if printf '%s\n' "$out" | grep -q 'Could not find type'; then
  echo "GD: hint: a new class_name is not in the global class table until the"
  echo "GD:       project is re-imported. If this type was added this session:"
  echo "GD:         .claude/scripts/gd.sh --headless --import"
  echo "GD:       then re-run this command. Costs one launch; a genuinely"
  echo "GD:       missing type fails again identically."
fi

echo "GD: exit=$status script_errors=$script_errors log=${log:-none}"
exit "$status"
