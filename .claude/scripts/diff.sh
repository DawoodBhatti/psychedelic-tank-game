#!/usr/bin/env bash
#
# Read the working-tree diff, in ONE command an allow list can approve.
#
# `Bash(git diff*)` is already allowed, and a plain `git diff` has never
# prompted. What prompts is the decoration:
#
#   git -C "/c/.../psychedelic-tank-game" diff -- tutorial/tutorial.gd
#   cd "/c/.../psychedelic-tank-game" && git --no-pager diff --stat
#
# `-C` and `--no-pager` sit between `git` and `diff`, so the allowed prefix
# never matches; the second also leads with `cd`, which matches no rule, and is
# a `&&` chain in which every segment must clear the list on its own. Both are
# read-only. Both would have run silently if written plainly.
#
# Broadening the pattern to `Bash(git * diff*)` is the obvious fix and is ruled
# out on purpose: it also matches `git checkout -- diff`, which discards
# working-tree changes, and the deny list names only push --force, push -f,
# reset --hard and clean -fd. A wildcard in the middle of a git pattern buys two
# harmless prompts at the price of standing approval for a destructive command.
#
# So: the same move gd.sh and newest-log.sh already are. This needs no
# permission change at all - `Bash(.claude/scripts/*)` covers it - it is tracked
# in git, it shows up in a diff, and it can only ever run `git diff`.
#
# CLAUDE.md has said "do not prefix commands with `cd`" for some time and the
# Reviewer did it anyway. That is this project's own claim about remembered
# rules, demonstrated on itself.
#
# Usage - every argument is passed straight to `git diff`:
#   .claude/scripts/diff.sh                      # the whole working-tree diff
#   .claude/scripts/diff.sh --stat               # summary only
#   .claude/scripts/diff.sh -- player/player.gd  # one path
#   .claude/scripts/diff.sh main...HEAD          # against the base branch

set -u

# Resolve the repo root from this script's own location rather than trusting
# the working directory, so the diff is the repo's diff wherever it is called
# from. --no-pager because a pager with no tty hangs the tool call.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"

exec git -C "$repo" --no-pager diff "$@"
