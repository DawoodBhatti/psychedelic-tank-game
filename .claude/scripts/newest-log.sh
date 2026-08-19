#!/usr/bin/env bash
#
# Read the newest session log, in ONE command an allow list can approve.
#
# The hand-written form was:
#
#   cd "/c/.../logs" && LOG=$(ls -1 session_*.log | tail -1); grep '"type":"error"' "$LOG"
#
# The `$(...)` is the part that can never be allowlisted: what actually runs is
# not known until the shell expands it, so a text pattern has nothing to match.
# Every log read therefore prompted, and reading the newest log is the single
# most frequent thing the Reviewer does.
#
# This script does NOT launch the engine, and must not - count_godot_launches.py
# deliberately does not count it. Reading a log is the cheapest operation in the
# pipeline and billing it as an engine boot was a bug once already.
#
# `count` answers a different question: did the launches an agent REPORTED
# actually happen? A Doer once returned a detailed, correctly formatted report -
# a before/after table, `exit=0 script_errors=0`, `check_resources PASS`, "7 of
# the session's 40 launches" - when no engine had run in 42 hours. The numbers
# were inherited from a real run two days earlier, so they were plausible,
# internally consistent, and describing nothing. `gd.sh` writes exactly one
# fresh session log per launch, so counting recent logs answers it mechanically.
# The check has to live here because the obvious hand-written form is `find ...
# -mmin -60`, and `find` is not allowlisted, so the honest check was the one
# that cost a permission prompt.
#
# It counts launches, not WHOSE: a run the user started by hand, or another
# session, is in the number too. So it answers "did seven launches happen at
# all" - which is the question a fabricated report fails - and never "did THIS
# agent make them". Treat a count below the claim as proof, and a count at or
# above it as no evidence either way.
#
# That asymmetry has been misread in the dangerous direction, so the `count`
# output now says it out loud. An orchestrator checking on a killed Doer read
# `launches=1` and passed it into the resume brief as a measured baseline; the
# log was fourteen minutes older than the agent, which had made no tool calls
# at all. The per-session answer is the hook's: count_godot_launches.py keys a
# hooklib.Counter by session id under <temp>/claude-pipeline/godot-launches/,
# and prints the running total on every launch.
#
# Usage:
#   .claude/scripts/newest-log.sh                 # summary: errors + load time
#   .claude/scripts/newest-log.sh path            # just the path
#   .claude/scripts/newest-log.sh errors          # error/warning entries
#   .claude/scripts/newest-log.sh fps             # perf samples
#   .claude/scripts/newest-log.sh grep <pattern>  # arbitrary grep
#   .claude/scripts/newest-log.sh count [minutes] # ALL sessions, last N (60)
#   .claude/scripts/newest-log.sh -n 2 summary    # the run BEFORE the last one

set -u

LOGDIR="${GODOT_LOG_DIR:-/c/Users/dabha/AppData/Roaming/Godot/app_userdata/psychedelic tank game/logs}"

BACK=1
if [ "${1:-}" = "-n" ]; then
  BACK="${2:-1}"
  shift 2
fi

MODE="${1:-summary}"

# The timestamp in session_YYYYMMDD_HHMMSS_mmm.log sorts lexically, so plain
# `ls -1` is newest-last and needs no -t (which would follow mtime instead and
# disagree if a file were ever touched).
LOG="$(ls -1 "$LOGDIR"/session_*.log 2>/dev/null | tail -"$BACK" | head -1)"

if [ -z "$LOG" ]; then
  echo "LOG: no session logs found in $LOGDIR" >&2
  echo "LOG: set GODOT_LOG_DIR to override." >&2
  exit 1
fi

case "$MODE" in
  path)
    printf '%s\n' "$LOG"
    ;;
  errors)
    grep '"event":"error"\|"event":"script_error"\|"event":"warning"' "$LOG" || true
    ;;
  fps)
    grep -o '"fps":[0-9.]*' "$LOG" || true
    ;;
  grep)
    shift
    grep "${1:?newest-log.sh grep needs a pattern}" "$LOG" || true
    ;;
  count)
    MINS="${2:-60}"
    N="$(find "$LOGDIR" -name 'session_*.log' -mmin "-$MINS" 2>/dev/null | wc -l)"
    echo "LOG: launches=$N within ${MINS}m - ALL sessions and hand runs (wall clock)"
    echo "LOG: below a claim this is proof; at or above it, no evidence either way."
    echo "LOG: NOT this session's count - that is the number the launch hook prints."
    echo "LOG: newest=$LOG"
    ;;
  summary)
    echo "LOG: $LOG"
    # `"type":"error"` also carries warnings, so the two are counted apart -
    # a warning is worth reporting but is not a failure on its own.
    echo "LOG: errors=$(grep -c '"event":"error"\|"event":"script_error"' "$LOG") \
warnings=$(grep -c '"event":"warning"' "$LOG")"
    echo "--- errors / script errors ---"
    grep '"event":"error"\|"event":"script_error"' "$LOG" | head -20 || true
    echo "--- loading_complete ---"
    grep -o '"event":"loading_complete"[^}]*' "$LOG" | head -3 || true
    ;;
  *)
    echo "LOG: unknown mode '$MODE' (path|errors|fps|grep|count|summary)" >&2
    exit 2
    ;;
esac
