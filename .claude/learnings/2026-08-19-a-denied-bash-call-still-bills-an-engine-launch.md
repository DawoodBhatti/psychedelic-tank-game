# A denied Bash call still bills an engine launch

- date: 2026-08-19
- surfaced-by: orchestrator
- run: initial project scaffold (pipeline transplant + core mechanics)
- target: hook

**Evidence.** The first engine command of the session was written with a `cd` prefix:

```
cd "C:/Users/dabha/Documents/game dev/codebase/psychedelic-tank-game" && .claude/scripts/gd.sh --headless --import
```

`guard_bash_decoration` **denied** it. The engine never started - no `session_*.log` was
produced, and the retried command a moment later reported `log=none`, meaning no log existed
yet at all. But the hook output attached to that same denied call read:

```
Engine launches this session: 1 of 40. This is the authoritative count - report this number.
```

The successful retry then reported `2 of 40`. Eleven real launches later the counter read 11,
i.e. exactly one ahead of the truth for the whole session.

**Why it happens.** `settings.json` registers four PreToolUse hooks on the `Bash` matcher and
they all run for the call. `count_godot_launches.py` increments its on-disk counter and returns
`hooklib.context(...)`, which by design does *not* vote on the call; `guard_bash_decoration.py`
returns `hooklib.deny(...)`. The deny wins the decision, but the counter has already been
written, and nothing rolls it back. Ordering in `settings.json` does not fix it - a hook cannot
see another hook's verdict.

**What it suggests.** The count is described in its own message as *authoritative* and in
`CLAUDE.md` as the number to report, and `newest-log.sh count` is explicitly documented as
unable to answer the per-session question - so this is the only number anyone has, and it
drifts upward by one per denied command. It over-counts, so it fails safe (the wall arrives
early rather than late), which is the right direction but still means a run can be stopped
citing a budget it did not spend.

Options, cheapest first: have `count_godot_launches.py` also print the count it would have
charged rather than committing it, and commit on a later PostToolUse; or move the increment to
a `PostToolUse` hook on `Bash`, where the call has actually happened. The second looks correct
and is a matcher change plus moving the counter write - but it needs checking that PostToolUse
fires with the same `session_id`, which
`.claude/learnings/` in the parent project already has a note about
(`2026-08-17-is-the-env-session-id-the-hook-session-id.md`). Read that before touching this.

Not urgent: the error is one per denied engine command, and denied engine commands are rare
once the decoration rule is internalised.
