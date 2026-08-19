#!/usr/bin/env bash
#
# The one wrapper for every hook. settings.json calls:
#
#     bash .claude/hooks/run.sh <name> [args...]
#
# which runs .claude/hooks/<name>.py under whichever python exists, passing
# stdin straight through.
#
# There were seven of these files, one per hook, each a copy of the same four
# lines - and two of them had drifted. count-agent-spawns.sh and
# guard-git-push.sh, the two that BLOCK, were written with a bare `exec python`
# while the five advisory ones had the python3 fallback, so on a machine with
# only `python3` the loop guard and the push guard would fail to start. The
# harness treats a wrapper that errors as a non-blocking error: both would have
# been off, silently. One copy cannot drift from itself.
#
# The trade is that this file is now a single point of failure for every guard,
# which is why check_guards.py checks for it by name at session start.
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
name="${1:?run.sh needs a hook name}"
shift

script="$here/$name.py"

# A hook whose script is absent must not block work; check_guards.py reports it.
[ -f "$script" ] || exit 0

if command -v python >/dev/null 2>&1; then
  exec python "$script" "$@"
elif command -v python3 >/dev/null 2>&1; then
  exec python3 "$script" "$@"
fi

exit 0   # No interpreter: never block work.
