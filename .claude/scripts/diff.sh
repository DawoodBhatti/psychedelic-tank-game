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
# in git, it shows up in a diff, and it can only ever run `git diff`,
# `git status --porcelain` and `git rev-parse`, all three read-only.
#
# CLAUDE.md has said "do not prefix commands with `cd`" for some time and the
# Reviewer did it anyway. That is this project's own claim about remembered
# rules, demonstrated on itself.
#
# It diffs against HEAD, not against the index
# --------------------------------------------
# A bare `git diff` shows the working tree against the INDEX, so a change that
# has been staged is invisible to it. Measured 2026-08-27: session D's 29 files
# were committed and then soft-reset, leaving everything staged.
#
#   $ .claude/scripts/diff.sh | wc -l       -> 0
#   $ git --no-pager diff HEAD --stat       -> 29 files changed, 1428 insertions(+)
#
# The Reviewer would have received an empty diff, exit 0, and nothing to tell
# "nothing changed" apart from "everything is staged". That state is not exotic
# - staging and then reviewing is a workflow this pipeline itself produces - so
# the tool went silent exactly where it was being relied on.
#
# Hence: when no revision is named, HEAD is supplied, and the answer becomes
# "what changed since the last commit" whether or not anybody ran `git add`.
# Naming a revision yourself turns the default off.
#
# And when there is nothing to print, it SAYS which nothing it means, on
# stderr, so a pipe into `wc -l` still shows the message. Untracked files
# appear in no diff at all, so that case is named too. A tool whose empty
# output is ambiguous between two opposite meanings is worse than no tool,
# because the reviewer proceeds.
#
# Usage - every argument is passed straight to `git diff`:
#   .claude/scripts/diff.sh                      # everything since HEAD, staged or not
#   .claude/scripts/diff.sh --stat               # summary only
#   .claude/scripts/diff.sh -- player/player.gd  # one path
#   .claude/scripts/diff.sh main...HEAD          # against the base branch
#   .claude/scripts/diff.sh --cached             # the index alone, HEAD still implied

set -u

# Resolve the repo root from this script's own location rather than trusting
# the working directory, so the diff is the repo's diff wherever it is called
# from. --no-pager because a pager with no tty hangs the tool call.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"

git_() { git -C "$repo" --no-pager "$@"; }

# Did the caller name a revision (or a bare path) themselves? Anything before a
# `--` separator that is not an option is theirs, and the HEAD default steps
# out of the way. `--cached`, `--stat` and friends are options, so they keep it.
named=""
for arg in "$@"; do
  [ "$arg" = "--" ] && break
  case "$arg" in
    -*) ;;
    *) named="yes"; break ;;
  esac
done

# An unborn branch has no HEAD to diff against; leave it to plain `git diff`.
base=()
if [ -z "$named" ] && git_ rev-parse --verify -q HEAD >/dev/null 2>&1; then
  base=(HEAD)
fi

out="$(git_ diff ${base[@]+"${base[@]}"} "$@")"
rc=$?

if [ -n "$out" ]; then
  printf '%s\n' "$out"
  exit $rc
fi

# Empty. Say which empty this is - on stderr, so `diff.sh | wc -l` still shows
# it - because "nothing changed" and "you are looking in the wrong place" print
# identically otherwise.
status="$(git_ status --porcelain)"
if [ -n "$status" ]; then
  {
    echo "diff.sh: NO DIFF for these arguments, but the tree is NOT clean:"
    printf '%s\n' "$status"
    echo "diff.sh: untracked files (??) appear in no diff; \`git add\` them to see one."
  } >&2
else
  echo "diff.sh: no changes - tree and index are clean at $(git_ rev-parse --short HEAD 2>/dev/null || echo '(no commits)')." >&2
fi

exit $rc
