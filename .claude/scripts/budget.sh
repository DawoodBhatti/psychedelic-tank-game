#!/usr/bin/env bash
#
# Print this session's two budget counters, without launching anything.
#
#   .claude/scripts/budget.sh
#   BUDGET: agent turns 6 of 12, engine launches 32 of 40  (session 66dd6095)
#
# Why this exists
# ---------------
# The launch counter is written by count_godot_launches.py, which reports it in
# a hook line - but ONLY on a launch. So the one party that most needs the
# number, the orchestrator between two agents, could not read it without
# spending the thing it was trying to count, and had to take the outgoing
# agent's self-reported tally instead.
#
# Measured 2026-08-27: a Doer's final report read "Engine launches: 8 of 40"
# and enumerated eight log paths, which reads as careful accounting. The
# counter for that session finished at 32. The orchestrator had already carried
# "8 spent" into the Reviewer's brief as fact; it was caught only because the
# Reviewer's first launch printed the hook's own line and it said so.
#
# The counters are plain files on disk. Reading them costs nothing, needs no
# engine, and is covered by the existing `Bash(.claude/scripts/*)` allow rule,
# so this prompts for nothing.
#
# What the numbers are, exactly
# -----------------------------
# The same integers the hooks increment - not a re-derivation, not a guess, and
# not `newest-log.sh count`, which is wall clock across every session that ever
# ran and can only ever prove a shortfall.
#
# One known skew, documented in pipeline-notes: a Bash call that is DENIED by
# another guard has already been counted by the launch hook, and nothing rolls
# it back. So launches can read one high per denied engine command. It fails
# safe - the wall arrives early, never late - and it is the same number the
# hook prints, which is the point.
#
# A missing counter file is reported as missing rather than as 0. The counters
# are keyed by session id; if this ever runs somewhere that id differs, "no
# file" and "nothing spent" are opposite answers and must not look alike.

set -u

# tempfile.gettempdir() is what hooklib uses; TEMP is what it resolves to here.
root="${TMPDIR:-${TEMP:-${TMP:-/tmp}}}"
root="$(printf '%s' "$root" | tr '\\' '/')"
state="$root/claude-pipeline"

# hooklib.Counter's key: alnum, dash and underscore only, first 64 characters.
sid="$(printf '%s' "${CLAUDE_CODE_SESSION_ID:-}" | tr -cd 'A-Za-z0-9-_' | cut -c1-64)"
[ -n "$sid" ] || sid="nosession"

turns_file="$state/agent-turns/$sid"
launch_file="$state/godot-launches/$sid"

read_counter() {
  # The stored value, or the empty string if there is no file to read.
  [ -f "$1" ] || return 0
  tr -cd '0-9' < "$1"
}

turns="$(read_counter "$turns_file")"
launches="$(read_counter "$launch_file")"

turn_limit="${CLAUDE_AGENT_BUDGET:-12}"
launch_limit="${CLAUDE_GODOT_LAUNCH_BUDGET:-40}"

# Neither file: nothing has been counted yet, OR this is not the session the
# hooks key by. Those are opposite readings, so name both rather than print 0.
if [ -z "$turns" ] && [ -z "$launches" ]; then
  echo "BUDGET: no counter files for session ${sid} under ${state}."
  echo "  Either nothing has been spent yet this session, or the hooks are keying"
  echo "  by a different session id. A spawn or a launch creates the file."
  exit 0
fi

# agent-turns exists but godot-launches does not: the id is right (a spawn
# wrote one of them), so the engine genuinely has not been started.
[ -n "$turns" ] || turns=0
[ -n "$launches" ] || launches=0

echo "BUDGET: agent turns ${turns} of ${turn_limit}, engine launches ${launches} of ${launch_limit}  (session ${sid%%-*})"
echo "  The hooks' own counters. Report these, never a tally of your own."
