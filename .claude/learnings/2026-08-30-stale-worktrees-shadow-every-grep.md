# Stale worktrees under `.claude/` shadow every grep with pre-S0 values, and no diff shows them

- date: 2026-08-30
- surfaced-by: orchestrator
- run: /begin S3 - The big world
- target: config

**Evidence.** `.claude/worktrees/` holds two complete copies of the project,
`fervent-grothendieck-c534dc/` and `vibrant-ritchie-d4be54/`. A `find` for source files
returned **three** copies of every one. They are not stale by a little: they predate S0, and
they still contain files S2 deleted.

The first grep of this session, for the terrain mapping parameters S3 is entirely about,
returned the worktree copies **ahead of the real file** - `.claude/` sorts before `terrain/`:

    ./.claude/worktrees/fervent-grothendieck-c534dc/terrain/fields/world_field.tres:14:height_scale = 0.04
    ./.claude/worktrees/fervent-grothendieck-c534dc/terrain/fields/world_field.tres:16:world_size = Vector2(192, 192)

Both values are superseded. The live file has carried `height_scale = 0.08` and
`world_size = Vector2(384, 384)` since S0 landed on 2026-08-29, and S3's entire premise is
the arithmetic relating those two numbers. The same grep also still finds
`entities/enemy_body.gd`, `entities/guardian_placeholder.tscn` and
`entities/prop_placeholder.tscn` - all deleted by S2 and recorded as deleted in its landed
note - so a grep for any symbol S2 removed reports it as still present.

Nothing surfaces this. They are excluded in `.git/info/exclude:7`, so `git status`,
`.claude/scripts/diff.sh` and every review diff are silent about them:

    $ git check-ignore -v .claude/worktrees
    .git/info/exclude:7:.claude/worktrees/	.claude/worktrees

**Test 2 is not affected, and that is the trap.** `DevHarness._all_resource_paths()` skips
dot-entries, so the Reviewer's `check_resources PASS {"checked":11}` is exactly the real
project's 11 resources. The resource walk is clean while the text search is not, so a green
sequence says nothing about this.

**Why it bites this pipeline specifically.** `CLAUDE.md` directs agents to read with the
Read / Grep / Glob tools rather than `cat`/`grep`, and the Doer's and Reviewer's tool lists are
built around that. The instrument the rules point every agent at is the one that returns the
stale copy first. An agent confirming a baseline number by grep - rather than by
`--harness-eval` against the live object, which costs a launch - gets a pre-S0 value that looks
authoritative and carries no marker that it is a copy.

**What it suggests.** Either delete the worktrees when their run ends, or fence them from
search the way `assets/incoming/.gdignore` fences a downloaded pack from Godot - a `.rgignore`
or an ignore rule the Grep tool honours. Deleting is one command and prevention is one file;
the failure it prevents is a wrong number adopted silently as a baseline, which is the class
this project's gates exist to catch and the one place they cannot look.
