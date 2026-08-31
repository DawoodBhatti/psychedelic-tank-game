# Pipeline notes

The reasoning, measurements and post-mortems behind the rules in `CLAUDE.md`. **Not
auto-loaded** — read it when changing the pipeline, not when changing the game. `CLAUDE.md`
is re-read on every turn of every session, so history in it is paid thousands of times;
history in here is free.

Grep this file, do not read it whole. During a `/consolidate` it answers exactly one
question per entry: *has this been decided before, and was it decided against?*

---

## Provenance: this pipeline was transplanted, not grown

- date: 2026-08-18

Everything under `.claude/`, plus `CLAUDE.md`, the autoloads and the marching-cubes terrain
code, came from `../flying-game-prototype` — a Godot 4.7 project whose repo is named
**marching-cubes-prototype** and whose `project.godot` calls itself `marching cubes
prototype`. The two names are the same project; that is why "use the flying prototype's
pipeline" and "siphon the marching-cubes work" resolve to one directory.

**The consequence worth knowing.** Every rule here was paid for by a failure in *that*
project, and the evidence for it is in *that* project's `.claude/pipeline-notes.md` (~1550
lines), which was deliberately not copied. An archive of post-mortems for defects this
codebase has not met is not history, it is folklore — and folklore is what `/consolidate`
exists to delete. When a rule here looks arbitrary, the evidence is at:

```
../flying-game-prototype/.claude/pipeline-notes.md
```

Read it there, and if the reasoning still applies, restate it *here* with what this project
measured. Do not copy the section across on the strength of the other project having
measured it.

**What was retargeted on arrival**, all of it mechanical:

| File | Change |
|---|---|
| `scripts/newest-log.sh` | `LOGDIR` to `app_userdata/psychedelic tank game/logs` |
| `hooks/count_godot_launches.py` | same path, in the docstring explaining why log reads are not launches |
| `hooks/guard_vacuous_eval.py` | example nodes retargeted from foliage to terrain chunks |
| `hooks/guard_write_path.py`, `hooks/guard_bash_decoration.py`, `scripts/gd.sh`, `scripts/diff.sh` | repo path in docstrings |
| `hooks/test_*.py` | fixture paths; all five suites re-run green after the edit |
| `surface-history.json` | emptied — the other project's byte counts are not a baseline for this one |
| `learnings/` | emptied to `README.md` |

`settings.json`, `model-sources.json`, `hooklib.py`, `check_render.py`, `check_surface.py`,
`usage_report.py`, the three agent files and the four commands crossed **unchanged**. They
contain nothing project-specific, which is itself the evidence that the seam is in the right
place.

The **log directory name is load-bearing and easy to get wrong**: Godot derives it from
`application/config/name` in `project.godot`, and it is configured nowhere else. Rename the
project and `newest-log.sh` silently reads the *old* project's logs — which exist, are
well-formed, and belong to something else. Change both or neither.

---

## The permission model

`settings.json` is the only settings file. `settings.local.json` is deliberately empty.

**Why the split matters.** Answering a permission prompt with "always allow" writes a rule
into `settings.local.json`, which is untracked and appears in no diff. In the parent project
that mechanism grew an 80-entry allow list one convenient click at a time, and it ended up
pre-approving `python -c`, `cp`, `mv` and `timeout` — arbitrary code from stdin, straight past
the write guard, with nothing in version control recording that it had happened. The list was
emptied three times.

Two things now hold that shut:

1. The rules that kept coming back — `Bash(python -)` above all — are in the **deny** list of
   `settings.json`. Deny beats allow wherever it is written, so the click no longer has an
   effect.
2. `check_guards.py` reports anything sitting in `settings.local.json` at session start, so a
   rule that did get added is visible rather than silent.

**The allow list is shaped around wrappers, not commands.** Permissions match command *text*,
and text is the wrong thing to match: `cd X && GD="$(...)" "$GD" --headless | grep HARNESS` is
entirely harmless and entirely un-matchable — `cd` matches no rule, the assignment differs from
any rule by a quote character, and `"$GD"` is not resolvable from text at all. Broadening
patterns until that line passes is how an allow list stops meaning anything. So the three
operations that happen constantly — launch the engine, read the newest log, read the diff —
each live behind one stable script under `.claude/scripts/`, tracked in git and reviewable in
a diff, and the allow list approves the *script*. Each of the three carries, in its header
comment, the specific pattern that could not be written.

`WebFetch` domains mirror `model-sources.json`'s `approved` list by hand. Promoting a site is
**two** edits — the entry moves in `model-sources.json`, and a matching `WebFetch(domain:...)`
goes in `settings.json`. With only the first, the site is vetted but still prompts on every
fetch, and that prompt is exactly what used to get answered with "always allow".

`curl`, `wget` and `Invoke-WebRequest` are denied on purpose. Asset downloading is a human
step by design; see `CLAUDE.md` § Out of scope.

---

## Two counters, two failure modes

`count_agent_spawns.py` (12 turns) bounds the **loop** — a Doer and Reviewer that will not
converge. `count_godot_launches.py` (40 launches) bounds the **cost inside** a pass, which is
where the money actually goes: one run in the parent project reported "2 of 25 iterations"
while spending roughly 45 engine launches. Neither counter resets, both are per session, and
that is why `CLAUDE.md` says one `/build` per session.

The launch counter charges an **invocation**, not the word "Godot". Its first version matched
the binary name anywhere in the command string and therefore billed a full engine launch for
*reading a log file*, because the log path contains `.../Godot/app_userdata/...` and reading
the newest log is the single most frequent thing the Reviewer does. A brake you cannot trust
is worse than no brake, because the run gets planned around a wrong figure.

`gd.sh` counts as a launch because it is one — and because the wrapper hides the binary from a
text-matching hook, so without that case the counter would have silently read zero from the
day the wrapper landed. This is why `gd.sh` is the only sanctioned way to start the engine and
why it launches **exactly once per invocation**: a test sequence must be several calls to it
rather than one script that loops, or the count stops being real.

### The counter over-reports by one per denied engine command — FIXED 2026-08-31

- date: 2026-08-19, folded 2026-08-26, fixed in fold 3 (see "The launch counter no longer
  charges for denied commands"). The history below is why, and is left as written.

`settings.json` puts four PreToolUse hooks on the `Bash` matcher. `count_godot_launches.py`
increments its on-disk counter and returns `hooklib.context(...)`, which does not vote;
`guard_bash_decoration.py` returns `hooklib.deny(...)`. **The deny wins the decision, but the
increment has already been written, and nothing rolls it back.** Ordering in `settings.json`
cannot fix it — a hook cannot see another hook's verdict. Observed at scaffold time: a `cd`-
prefixed `gd.sh` call was denied, no engine started and no `session_*.log` was produced, yet
the hook reported `1 of 40`; the successful retry reported `2 of 40`, and the count stayed
exactly one ahead of the truth for the rest of the session.

It fails **safe** — the wall arrives early rather than late — which is why this has not been
rushed. But the number is documented as authoritative in its own message and in `CLAUDE.md`,
and `newest-log.sh count` explicitly cannot answer the per-session question, so it is the only
figure anyone has.

The fix is to move the commit to a `PostToolUse` hook on `Bash`, where the call has actually
happened, leaving PreToolUse to read, deny at the wall, and report `used + launches` as a
projection. **One of the two things that blocked it is now measured.** The parent project's
`2026-08-17-is-the-env-session-id-the-hook-session-id.md` left open whether the id the hooks
key counters by is the session's own id; it is:

```
$ echo $CLAUDE_CODE_SESSION_ID          -> 84063494-…-c13c243d2ba8   (= scratchpad path uuid)
$ ls <temp>/claude-pipeline/godot-launches/
5e800ec0-…-e5dde2895c57   a2742607-…-ee3f985521af   …
$ ls <temp>/claude/C--Users-…-psychedelic-tank-game/
5e800ec0-…-e5dde2895c57   a2742607-…-ee3f985521af   …   84063494-…-c13c243d2ba8
```

Two counter filenames appear verbatim as session scratchpad uuids, and the env id equals this
session's scratchpad uuid. So a hook payload's `session_id` **is** the session uuid, and a
`PostToolUse` hook keyed the same way would find the same counter file.

What remains unverified is whether `PostToolUse` fires on the `Bash` matcher at all and what
its payload carries. The fold that measured the above could not test it: **editing
`settings.json` is refused by the harness's auto-mode classifier**, so the probe hook could not
be registered. Do not ship the move on the assumption — that is the defect class the parent
project's fold 6 exists to close. Register a throwaway probe in a session where the edit is
permitted, confirm the event fires and carries the id, then move the increment.

---

## Why the harness exists at all

No external process can reach into a running Godot scene tree to move a camera, read a value
or check a state. Only code inside the engine can. Before `autoloads/DevHarness.gd` that meant,
per question: write a throwaway script, register it as an autoload, run, read the result,
unregister it and delete the file — six manual steps, with a temp autoload left registered
whenever anything went wrong in the middle. The harness is that hatch made permanent and
inert: with no `--harness-*` argument it returns immediately from `_ready()` and cannot ship
by accident.

`--harness-eval` repeats **because batching is the whole cost model**. Each launch is a full
engine boot plus a terrain rebuild, so thirteen questions asked separately cost thirteen boots
and the same thirteen batched cost one.

**One launch runs one harness command** — the dispatcher quits after whichever matched. So a
launch can mutate the scene *or* photograph it, never both in that order, and anything visible
only after a mutation is reported unverified. That bites this project specifically: carving a
crater and then photographing the hole is two launches, and the eval that carves cannot also
show you the result.

---

## Why the terrain is CPU marching cubes and not a heightmap

The README asks for two things that pull in opposite directions: procedural hills, and terrain
that a shell can blow a hole in. A heightmap gives the first cheaply and cannot do the second
at all — a crater in a heightfield is a dent, never an overhang, never a tunnel, and never a
hole you can see daylight through.

A signed distance field gives both, and gives destruction for free as an *authoring*
operation rather than a mesh operation: `SDFOps.op_subtract(terrain, sphere)` is the whole of
"blow a hole in it". The cost moves to re-meshing, which is bounded because only the chunks a
crater's radius actually touches need rebuilding.

The parent project's `chunk.gd` came across nearly whole. The one structural change is that it
now separates `generate()` from `rebuild()`: the original always did `add_child(StaticBody3D)`
at the end of meshing, so calling it twice on the same chunk left a second collider stacked on
the first, invisible in every test and lethal in exactly the way collision bugs are. Craters
call `rebuild()`, which reuses the body and swaps the shape.

The compute-shader marching cubes under `../procedural-landscapes/marching cubes/` was
considered and **not** used: it is written against the Godot 3 API (`PoolRealArray`,
`translation`, argument-less `storage_buffer_create()`) and does not run. It is a sketch, not
an implementation. If GPU meshing is ever wanted here, start from the working CPU version and
port it, not from that file.

---

## Fold 1 — 2026-08-26

Five entries in, five out. **`SURFACE: 55049 → 55785, +736`** against the transplant baseline,
measured before this section was written. The first draft of the fold measured **+2444**; the
difference is entirely compression of the additions and four duplications cut, and it is worth
recording that the honest first number was three times the defensible one. `doer.md` (-390) and
`reviewer.md` (-234) both came out smaller.

**Evidence stripped off the in-force surface and kept here.** Each rule below is stated in one
line where an agent will meet it; this is the measurement that bought it.

- **The before batch is the whole harness surface** (`build.md`). Session B's gate was "nothing
  visibly changes" and the brief named three quantities — `chunks_total`, `terrain_triangles`,
  `surface_height_range()`. The refactor moved `spawn_clearance` into `LevelDef`, and
  `tank_spawn_height` (= `surface_height(0,0) + spawn_clearance`) sat directly downstream of it
  and was not in the batch. The Doer reported it plainly: "no true BEFORE value — my omission
  from the first batch, and unrecoverable", and reconstructed it by inference. Eight
  harness-facing names were enumerable from `main.gd`'s header at the time; `--harness-eval`
  repeats, so all eight were the same single boot as three. A "before" is the one measurement
  that cannot be re-taken, so the selection rule cannot be "what the task is about".

- **A resource reference is proved by `resource_path`, not by a number** (`CLAUDE.md § Traps`).
  Session B moved `field` off the `Terrain` node into `levels/valley.tres`, assigned by
  `LevelRunner._apply_level()` but only `if level.field != null`, with `Terrain._ready()`
  building `TerrainField.new()` as a fallback. Every value in `world_field.tres` equals the
  `@export` default of the script it instantiates (`amplitude 22.0, frequency 0.011,
  noise_seed 1337, octaves 4, persistence 0.42, plateau_strength 0.25, plateau_step 6.0,
  vertical_offset 0.0`, `crater_blend 2.0`). A `valley.tres` that silently failed to resolve
  would therefore still have produced `chunks_total 32`, `terrain_triangles 28414` and
  `surface_height_range() (-9.792703, 8.059858, 2.712966)` — the exact three numbers offered as
  proof the gate held. This is *not* the "statistic computed by the change" trap: the statistic
  is genuinely independent, but both code paths compute the same one.

- **No frame runs inside an eval batch** (`CLAUDE.md § The dev harness`, `doer.md`).
  `main.gd` exposed `explosions_spawned` as a var refreshed from the effects director in
  `_process()`. One batch emitted the signal and read it back:
  ```
  scene.explosions_spawned                                    = 0
  root.get_node("GameEvents").shell_exploded.emit(…)          = <null>
  scene.explosions_spawned                                    = 0   <- wrong
  scene.terrain.craters_carved                                = 1   <- right, read off the owner
  ```
  Both listeners had run. `_cmd_eval` executes every expression in one pass, so `_process()`
  never ran to copy the value across. The dangerous part is the *shape* of the wrong answer:
  `0` against a signal that fired correctly reports "the connection is broken" about a
  connection that works, on a run that compiles, passes resources, logs nothing and renders —
  and the obvious next move is to go and "fix" correct signal wiring. `doer.md` previously read
  as an endorsement of exactly this mirror; it now asks for a computed getter, or recording on
  the code path that writes the value, and bans the per-frame refresh.

**Dropped, with reasons.**

- **Incremental writes for the modeller's `.candidates.json`.** The entry proposed appending
  each candidate as verified, capping an interruption's loss at one candidate instead of a
  whole run — and handed over the tension itself: a partially written file is
  indistinguishable from a finished one, so it needs a completeness marker, which is a schema
  change to the artifact `source-model.md` calls "the seam a different search backend plugs
  into later". **Not folded.** The measured recovery path already works and is cheap: the run
  that died on an API error at "All verified. Writing the shortlist." after 63,484 tokens / 56
  tool uses / ~29 minutes was resumed via `SendMessage` for 74,580 tokens and **2 tool uses**,
  with no re-searching. The real gap was that `source-model.md` named `SendMessage` only for
  the "none of these" path, so nothing told an orchestrator to resume a *killed* modeller —
  one line, no schema churn. Note the cost is invisible to both budget counters, since
  `/source-model` spends zero engine launches; that is a known blind spot, not a new one.

- **`reviewer.md`'s collision-layer restatement.** Not from an entry — found while reading. It
  read "Layer 2 is the wing-kill layer; a prop that should be scenery landing on it kills the
  player on contact", which is the *parent* project's fact set surviving the transplant into a
  game with no wings, and it contradicted `CLAUDE.md § Code standards` (layer 2 is the tank).
  Replaced with a pointer. This is the third instance of the same failure — a rule restated in
  an agent file, then drifting, with the stale copy being the one the agent runs — and it is
  why the three test-sequence rationales were also collapsed to pointers this fold.

---

## Fold 2 — 2026-08-27

Three entries in, three out. **`SURFACE: 55785 → 56207, +422`**, measured before this section
was written. **It went up, and 226 of it is one JSON block** — the `settings.json` registration
for a new hook. The three prose-bearing files moved +196 between them, and the fold's one
duplication (the same launch-count evidence written into both `CLAUDE.md` and `build.md`) was
cut on the second measurement, worth -108.

That trade is the point rather than an excuse: two of the three entries left the auto-loaded
surface entirely and became executable, and a hook costs its bytes once in a config file
instead of on every turn of every session.

**Evidence stripped off the in-force surface and kept here.**

- **A self-reported launch count is not the counter** (`scripts/budget.sh`,
  `CLAUDE.md § Budgets`). Session D's Doer closed its report with "Engine launches: **8 of
  40**" and enumerated eight `session_*.log` paths beneath it, one of which was in fact the
  orchestrator's own before-batch. The orchestrator carried "8 spent" into the Reviewer's brief
  as fact. The Reviewer's first launch printed the hook line reading **17** and it said so.
  The counter file for that session (`<temp>/claude-pipeline/godot-launches/66dd6095-…`) was
  read during this fold and holds **32**: the report was wrong by a factor of four, while
  presenting itself as careful accounting.

  The structural cause is that the authoritative number was only ever *printed on a launch*, so
  the orchestrator between two agents could not read it without spending the thing it was
  counting, and `newest-log.sh count` is wall clock across all sessions. The counters are plain
  files; `budget.sh` reads both and costs nothing. Prose was already in place telling agents to
  take the hook's number — it did not survive contact with an agent that had done its own
  arithmetic, which is the argument for a command over a rule.

  It reports a **missing** counter file as missing rather than as 0, and distinguishes the two:
  an `agent-turns` file with no `godot-launches` file means the session id is right and the
  engine genuinely has not started. Verified against three recorded sessions
  (`66dd6095` → 6/32, `94c90081` → 3/0, this session → neither file).

- **`diff.sh` was silent on a staged tree** (`scripts/diff.sh`). Session D's work was committed
  and soft-reset, leaving all 29 paths in the index. On that tree `.claude/scripts/diff.sh |
  wc -l` printed **0** while `git diff HEAD --stat` printed **29 files changed, 1428
  insertions(+)**. A bare `git diff` compares the working tree to the *index*, so staging
  hides a change from it completely — and the Reviewer, whose one instruction is to read the
  diff with that script, would have received an empty result and exit 0 with nothing to
  separate "nothing changed" from "everything is staged". The pipeline's own
  stage-then-review workflow creates the state.

  Fixed by supplying `HEAD` when the caller names no revision, so the question becomes "what
  changed since the last commit" regardless of `git add`; naming a revision turns the default
  off. Empty output now says which empty it is, on **stderr**, so a pipe into `wc -l` still
  shows it, and names untracked files separately because they appear in no diff at all.
  Reproduced end to end during the fold: staged tree, `diff.sh | wc -l` → **98**, index
  restored.

  The entry proposed `agent-file` as the target. It went a rung higher on purpose — the tool
  is wrong for every caller, not just the Reviewer, and `reviewer.md` needed **no edit at all**
  once the script was fixed. A rule telling the Reviewer to distrust an empty diff would have
  been a rule about a bug.

- **An eval that constructs a node cannot free it, and the leak reads as a game defect**
  (`hooks/guard_eval_orphan.py`). `scene.tank.shell_scene.instantiate().hit_mask` returns the
  right number and leaves orphaned RIDs, which Godot reports at exit into
  `session_20260827_122612_354.log` — the same session log `CLAUDE.md` test 3 fails the run on.
  `Expression` evaluates one expression: nowhere to bind a temp, nowhere to sequence a `free()`.
  The cost was not the leak but the argument about whose leak it was: the Doer had to defend it
  in its report and the orchestrator had to pre-empt the attribution in the Reviewer's brief,
  or a launch would have gone on deciding whether the game leaked.

  Going through the game's own construction path parents the object and hands its lifetime to
  the tree. Measured on `session_20260827_123141_365.log`: `scene.tank.fire()` then reading
  `scene.get_child(scene.get_child_count() - 1)` gave `hit_mask` = 1, `shells_fired` = 1,
  `errors=0 warnings=0`, no leak lines — on a launch that also freed 17 entities through a
  second `scatter()`.

  The entry proposed `CLAUDE.md § The dev harness`, beside the other eval limits. It became a
  hook instead, on `guard_vacuous_eval`'s precedent and for its reason: a failure that is
  invisible in its own output — here, worse, *legible as something else* — is the case a
  remembered rule answers worst. The guard matches `instantiate(` only, which is a `PackedScene`
  method and always yields a Node, so there is no false positive to trade against; an
  `instantiate()` wrapped in `add_child(...)` is parented and allowed. 13 cases,
  `test_guard_eval_orphan.py`, all passing.

---

## Fold 3 — 2026-08-31

Sixteen entries in, sixteen out. **`SURFACE: 56207 → 66978, +10771` since fold 2**, measured
before this section was written. That figure is not all this fold's: `begin.md` (6136) was
written between folds and is new to the count, and `CLAUDE.md` had already drifted +541 in the
S-series sessions. **This fold's own share is +5079, of which `CLAUDE.md` is +2417** — by a
wide margin the largest single fold in this pipeline's history, against a command that asks for
roughly flat.

**Say plainly what that means: on this measure the fold did not work.** Sixteen entries is four
times any previous inbox and nine of them targeted `CLAUDE.md`, so some growth was owed — but
the first draft of this fold added +3437 to `CLAUDE.md` and a second pass over my own additions
cut a fifth of it back out as evidence that belonged here. Every addition was compressed to the
rule; every measurement it rests on is in this section. The one structural cut available was
taken (below). It was not enough, and the next fold should open by asking what comes OUT.

**The one cut, and the category it came from.** `CLAUDE.md § The loop` carried ~840 characters
of agent-resumption procedure — recover from disk, restate what was measured, when to open an
`.output` transcript. Only an orchestrator can act on any of it: the Doer and the Reviewer
cannot spawn an agent or send it a message, and they paid for those bytes on every turn. Both
halves already existed in the orchestrator files (`begin.md § 1` for the `in-progress` case,
`build.md § The cycle` for the send-back). Cut to a three-line pointer; the unique content —
the killed-mid-run case and the transcript advice — moved into `build.md` beside the send-back
rule it belongs to. Net surface ~0, but the file paid thousands of times is smaller.

**Evidence stripped off the in-force surface and kept here.**

- **A `--harness-eval` batch fails as a unit.** 50 expressions in one launch
  (`session_20260828_140810_367.log`) returned 47 correct values and 3 errors — `Invalid named
  index 'world_size' for base type Object`, from addressing `field.ground` instead of
  `field.ground.layers[0]`. The launch ended `HARNESS: eval FAIL {"count":50,...}` and
  `GD: exit=1 script_errors=0`, with every good value in the same stdout. Two rules in
  `CLAUDE.md` interacted the wrong way round: "prefer branching on the exit code" and "batch
  every question into ONE launch". The harder you batch, the more a single typo takes down.
- **`--harness-eval` cannot assign.** `scene.terrain.destructible = true` → `{"error":
  "Expected '='"}`; the batch carried on and the next read returned `false`, the pre-write
  value. `scene.terrain.set('destructible', true)` is a call, parses, and runs the GDScript
  setter — proven in the same batch by a connection count moving to 2
  (`session_20260828_135637_478.log`).
- **A failed read means the wrong object more often than the wrong value.**
  `scene.terrain.field.ground.max_world_gradient` errored, `.get('max_world_gradient')`
  returned `<null>`, `['max_world_gradient']` errored — while `.vertical_extent()` and
  `.surface_height(0,0)` on the same object returned correct numbers. One expression settled
  it: `.get_script().resource_path` → `res://terrain/sdf/SDFComposite.gd`. The property was on
  `layers[0]`, and returned `1.89957169805485` first try. Cost: 2 launches spent on a wrong
  theory about `get()` on Resources. The `<null>` form is the dangerous one — a missing
  property and a real null print identically.
- **The const trick needs a live instance.** `entities/CollisionLayers.gd` is a `class_name`
  holder deliberately never instantiated. Both routes fail: `CollisionLayers.PLAYER_SHELLS` →
  `Invalid named index 'CollisionLayers' for base type Object`, and
  `load("res://entities/CollisionLayers.gd").get_script_constant_map()` → `On call to 'load':`
  (logs `session_20260830_105556_362.log`, `session_20260830_105637_366.log`).
  `DevHarness._cmd_eval` parses with `expr.parse(source, ["scene","tree","root"])` and executes
  against `self`, so global script classes and `load` do not resolve. The consequence for
  reserved collision bits is in `CLAUDE.md § Code standards`: they are reserved *because* no
  body carries them, so the only evidence is
  `(tank.collision_layer | tank.collision_mask) & 20 = 0` plus a source read.
- **A sweep resolves nothing along the axis it does not cut.** A 30-column sweep of
  `x 0.35–0.65, y 0.55–0.85` reported `delta.luma_mean` "oscillating ±5–8 with a ~4-strip
  period" as evidence of contour banding. Each strip averaged 498 px of height — many contour
  lines — so what it measured was terrain shape varying in x, and it would have appeared on a
  control with no contours in it. The same frame in 40 explicit horizontal strips (~4 px tall)
  showed the real structure: troughs at `delta.luma_mean` −0.7 / +0.4, peaks at +28.8, period
  ≈29 px, `delta.hue_frac.grey` moving in phase (+0.24 → +0.68). Both sweeps "showed banding".
  This is now `--rows`, with the reasoning in the script's own docstring.
- **A control shot is a control only for its commit.** S1b's gate named
  `.claude/images/s1-contours-before.png`, which is S1's *pre-contour* frame — and S1's commit
  (7c0a5a8) changed two things at that pose: the contours, and `emission_strength 2.4 → 1.6`,
  `line_width 0.045 → 0.035`. Against it, a pure contour *fade* measures as **adding** +14.9
  luma, which a fade cannot do. The mtime argument advanced at the time is unsound — `/begin`
  commits after the session ends, so every image predates its own commit. The sound test needs
  no launch: `check_render.py s1-review-after.png --control s1-contours-after.png` measures
  delta 0 on every field, while `s1-contours-after.png --control s1-contours-before.png`
  measures +14.9 luma / +0.391 grey.
- **A per-shape dedup test passes vacuously when the query returns one shape.** A blast 4.0
  units from a tower with no direct target took `Damageable.health` 100.0 → 95.0, one
  application of `splash_damage_at(4.0)=5.0` — which reads exactly like a dedup pass and tests
  nothing, because tower.tscn's shaft spans y0–20 and its cap y20–23.2, so an 8-unit sphere at
  the base overlaps ONE shape and an un-deduped loop prints the same 95.0. Confirming it needed
  a second launch: `set("blast_radius", 30.0)` and a blast at `tower + (0,20,0)` overlaps both,
  giving 100.0 → 96.0 against 92.0 un-deduped. The shipped geometry cannot reach the path at
  all — any point overlapping both shapes is ≥12 units above the origin, and splash is measured
  to the origin against an 8-unit radius.
- **A stale `.godot/` after a deletion has no symptom.** After removing `enemy_body.gd`,
  `guardian_placeholder.tscn`, `prop_placeholder.tscn` and `profiles/guardian_hull.tres`:
  `test 1 GD: exit=0 script_errors=0` (`session_20260830_104448_365.log`) and `test 2
  check_resources PASS {"checked":9,"failed":[]}` (`session_20260830_104459_360.log`), while
  `global_script_class_cache.cfg` still registered `EnemyBody → res://entities/enemy_body.gd`
  and `filesystem_cache10` still recorded `valley.tres` depending on both deleted scenes. No
  `Failed loading resource:` was ever emitted. After `rm -rf .godot` + `--headless --import`
  both tests are green again, indistinguishable from the green they gave over the stale cache.
  Now warned by `diff.sh`, which the Reviewer already runs.
- **The dirty-tree pre-flight named the wrong risk and offered a fix that destroys the
  baseline.** `build.md` said a dirty file leaves no obtainable "before" and suggested "commit
  or stash first". Both halves were false in the run that found it. The before *was* obtainable
  — it lives in the working tree, and one batched launch
  (`session_20260828_134113_366.log`, 34 expressions) captured `terrain_triangles 23672`,
  `max_world_gradient 1.89054`, `shell_exploded.get_connections().size() 2`, every later
  comparison in the run being made against those. And stashing would have destroyed it: HEAD
  (`8b84b95`) was the fBm-hills world, while the Glen Coe DEM existed only in the working tree,
  so the widening — whose acceptance criterion was `max_world_gradient` coming back unchanged —
  would have been tuned against terrain the user had already replaced. The real risk of
  proceeding dirty is that `git checkout` can no longer separate this task's damage from the
  uncommitted work already there, which argues for committing and only for committing.

### Authoring roadmap gates

Two entries, one shape: a gate is written before the code exists, by someone who has not shot
the frame or run the round-trip. It binds a Doer that will read it literally.

**A gate may prescribe a method that cannot work.** S1b's gate said "shoot the valley floor
from two distances — (a) changes with the grazing angle, (b) does not." Both poses saturated at
the bottom band — luma 250, `hue_frac.grey` 0.62, `hue_frac.orange` ~0.0003 — because a
near-horizontal view maximises the shader's rim term across the whole ground and swamps the
contour contribution. The Doer substituted two measurements the gate had not named: sampling
`1 - |n.y|` off the live chunks (valley floor 0.0000–0.0036 against hillsides 0.0140–0.2295),
and arithmetic showing a minor line emits luminance ~1.20 against a 0.85 glow threshold
everywhere in the frame, which rules out (b) on its own premise. The diagnosis was sound and
the prescribed method contributed nothing. So: gates prescribe the **question and the standard
of evidence**; a method inside one is a suggestion. `begin.md § 4` now says so.

**A clause that samples state across a synchronous emit is a constraint on timing, not
behaviour.** S4b's gate said the player "survives two direct hits and dies on the third (`alive`
reads true, true, false)". A correct implementation of everything else the section asked for
reads **true, true, true**: `_on_destroyed()` emits `level_reset_requested`, `main.gd` calls
`tank.respawn()` inside that same call, and `alive` is back before the caller returns — and the
section separately, rightly, insisted death route into the reset path `death_height` already
used, so the emit is synchronous *by instruction*. The Doer closed the gap with
`@export var death_reset_delay = 1.6`, a dial the roadmap never asked for, and said so plainly;
the Reviewer judged it legitimate on game-feel grounds but recorded that setting it to 0 returns
the gate to true/true/true with no code change. The gate therefore tested "dies on the third hit
**and stays dead longer than one call frame**", and only the first half was written down. Write
such a clause against something the round-trip does not restore — a signal count, a respawn
counter, `is_alive` sampled inside the handler — or name the delay in the section as a dial, the
way S4b named the 3:1 toughness ratio. This one is filed here and nowhere in force: roadmap
sections are authored in planning sessions that no auto-loaded file governs, which is a real gap
and the honest place to record it.

### Stale worktrees: Grep is clean, Glob is not

`.claude/worktrees/` held two complete copies of the project — `fervent-grothendieck-c534dc`
and `vibrant-ritchie-d4be54`, 25M each, both predating S0 and both still holding files S2
deleted. They are listed in `.git/info/exclude:7`, so `git status`, `diff.sh` and every review
diff are silent about them, and `DevHarness._all_resource_paths()` skips dot-entries, so
`check_resources PASS {"checked":11}` is the real project's 11 resources. A green sequence says
nothing about this.

The entry proposed fencing them from search "the way `assets/incoming/.gdignore` fences a pack".
Measured, that is not the shape of the problem:

    Grep  height_scale              -> terrain/fields/world_field.tres, no worktree copies
    Glob  **/world_field.tres       -> both worktree copies FIRST, then the real file
    Glob  **/global_script_class_cache.cfg -> worktree copies of a .gitignored path

`Grep` is ripgrep and honours `.git/info/exclude`, so it was never exposed. `Glob` honours no
ignore file at all — it returns `.godot/` contents — and sorts by mtime, so a worktree copy
outranks the file it shadows. **No ignore file can fix Glob**, which leaves removal as the only
fix and made this a reporting problem rather than a fencing one: `check_guards.py` now names any
worktree it finds at session start, with `git worktree remove` and the note that the branch
survives. The removal itself is the user's, not an agent's.

### The launch counter no longer charges for denied commands

The over-count documented above under "Two counters, two failure modes" is **fixed**, and not by
either route that section was waiting on. A third observation arrived first: an fps run reported
"14 of 40", a `--harness-eval` batch containing
`scene.tank.shell_scene.instantiate().hit_mask` was denied by the orphan guard and reported
"15 of 40" with no `GD:` line and no engine output, and the corrected retry reported "16 of 40".
The log directory confirms it — `session_20260831_080820_458.log` is followed directly by
`session_20260831_081258_317.log`, nothing in the four-minute gap. One boot, two increments.

The section said "ordering in `settings.json` cannot fix it — a hook cannot see another hook's
verdict", and that is true and was the wrong place to stop. A hook cannot see another's verdict,
but it can ask the same *question*: all three denying `Bash` guards already computed their
refusal in a pure function (`offenders()`, `offence()`). Each now exposes `would_deny(command)`
and decides through it, so the answer given to a caller cannot drift from the decision the guard
makes. `count_godot_launches.py` reads the guard list out of `settings.json` — the same
anti-drift move as `check_guards.py` — imports each, and skips the increment when any says yes.
A guard added later needs only a `would_deny`; one without is skipped and the count is unchanged.
Failure is open in the *expensive* direction on purpose: any error reading settings, importing a
guard or calling its predicate falls through to counting, because an uncounted launch is a budget
that lies low.

No `PostToolUse` probe was needed, and `settings.json` was not touched. Verified by seven cases
in `test_count_godot_launches.py` — the three denial forms, including the exact expression from
the evidence above, and their four corrected twins — with all 29 counting cases still passing.

## Open questions for this project

Written down so they are not re-derived from scratch, and so a `/consolidate` can see what is
still unsettled. None of these is a rule.

- **Whether the render check can see a crater.** `check_render.py --region ... --control
  before.png` is the tool, and terrain carving is the first change class here where the
  subject is a *hole* rather than an added object. A hole reads as a luma and hue change
  against untouched terrain, which is a genuine control — but the box has to be sized to the
  crater, and "a sweep resolves nothing finer than one column" applies. Unmeasured so far.
- **Whether chunk regeneration cost belongs in the fps test.** A carve rebuilds one chunk's
  mesh and collision synchronously. If that lands inside a sampled second it sets the minimum,
  and test 4 thresholds on the worst sample by design. Whether that reads as a real stall or a
  measurement artefact is not yet known; measure before tuning either.
- **Whether `craters_carved` is independent evidence.** It is state written on the same code
  path that does the carving, which `CLAUDE.md` warns is a re-execution rather than a check.
  The independent quantity is the chunk's `mesh.get_aabb()` and its triangle count, which
  change shape when material is actually removed and read back non-empty headless.
- **Whether a `Node.new()` inside an eval leaks the way `instantiate()` does.** It should —
  same absent `free()` — but `guard_eval_orphan.py` deliberately does not match `.new()`,
  because most `.new()` calls in an eval are RefCounted (`RandomNumberGenerator`, any
  `Resource`) and free themselves, and no text guard can tell the two apart. Nobody has hit the
  Node case here yet. If one is measured, that is an inbox entry with a log path in it, not a
  reason to widen the pattern now.
- ~~**Whether the counter's known over-count now matters more.**~~ Closed 2026-08-31: the
  counter now asks each denying `Bash` guard `would_deny(command)` and does not bill a call
  that will be refused. `PostToolUse` remains unprobed and is no longer needed for this.
