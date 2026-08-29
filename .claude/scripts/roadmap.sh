#!/usr/bin/env bash
#
# Print the roadmap's status and the next runnable session. No engine launch.
#
#   .claude/scripts/roadmap.sh          # the table, plus NEXT
#   .claude/scripts/roadmap.sh next     # just the next session's id
#
# READ-ONLY, DELIBERATELY. /begin updates docs/roadmap.md with Edit, which the
# write guard walls; a `sed -i` from here would be a write the guard cannot see
# (CLAUDE.md § Guards). This script only ever reads.
#
# The next runnable session is the FIRST non-done one, because the roadmap is a
# linear chain - every session depends on the one above it. If that session is
# blocked, nothing later is runnable either, so it says so and stops rather than
# skipping ahead to work whose ground has not been laid.

set -u

file="docs/roadmap.md"
[ -f "$file" ] || { echo "ROADMAP: $file not found (run from the repo root)."; exit 1; }

mode="${1:-report}"

# One record per session: id, status, title, and the blocked-on / resume note if
# there is one. Sections are `## S<n> - <title>`; fields are `- <key>: <value>`.
parse() {
  awk '
    /^## S[0-9]+ / {
      id = $2
      title = $0
      sub(/^## S[0-9]+ [^ ]* /, "", title)
      status = "?"; note = ""
      order[++n] = id
      titles[id] = title
      next
    }
    id != "" && /^- status: / { status = $3; statuses[id] = status; next }
    id != "" && /^- (blocked-on|resume): / {
      note = $0; sub(/^- /, "", note); notes[id] = note; next
    }
    END {
      for (i = 1; i <= n; i++) {
        k = order[i]
        printf "%s\t%s\t%s\t%s\n", k, (k in statuses ? statuses[k] : "?"), titles[k], (k in notes ? notes[k] : "")
      }
    }
  ' "$file"
}

records="$(parse)"
[ -n "$records" ] || { echo "ROADMAP: no sessions found in $file."; exit 1; }

next_id=""
next_status=""
next_title=""
next_note=""
while IFS=$'\t' read -r id status title note; do
  [ "$status" = "done" ] && continue
  [ -n "$next_id" ] && continue
  next_id="$id"; next_status="$status"; next_title="$title"; next_note="$note"
done <<< "$records"

if [ "$mode" = "next" ]; then
  [ -n "$next_id" ] && echo "$next_id" || echo "none"
  exit 0
fi

done_n=0; todo_n=0; other_n=0
while IFS=$'\t' read -r id status title note; do
  case "$status" in
    done) done_n=$((done_n + 1)) ;;
    todo) todo_n=$((todo_n + 1)) ;;
    *)    other_n=$((other_n + 1)) ;;
  esac
done <<< "$records"

echo "ROADMAP: ${done_n} done, ${todo_n} todo, ${other_n} blocked or in progress"
while IFS=$'\t' read -r id status title note; do
  printf '  %-4s %-12s %s\n' "$id" "$status" "$title"
done <<< "$records"

echo
if [ -z "$next_id" ]; then
  echo "NEXT: nothing left - every session is done."
  exit 0
fi

echo "NEXT: ${next_id} (${next_status}) - ${next_title}"
[ -n "$next_note" ] && echo "  ${next_note}"

case "$next_status" in
  blocked)
    echo "  BLOCKED. The chain is linear, so nothing after this is runnable either."
    echo "  Clear what it names, then re-run."
    ;;
  in-progress)
    echo "  Left unfinished. Recover from DISK - git status --short and the files it"
    echo "  wrote - before restating the brief (CLAUDE.md § The loop)."
    ;;
esac
