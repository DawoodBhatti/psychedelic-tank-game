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
