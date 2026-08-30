# Project Pipeline Rules — Godot 4.7 (GDScript + C#)

Operational rules only. The reasoning, measurements and post-mortems behind every rule here
live in `.claude/pipeline-notes.md`, which is **not** auto-loaded — read it when changing the
pipeline, not when changing the game. This file is re-read on every turn of every session, so
history in it is paid thousands of times. Keep it short; put the *why* in the notes.

**This pipeline was transplanted from `../flying-game-prototype`, not grown here** — where a
rule below looks arbitrary, it was paid for by a failure there. See provenance in
`.claude/pipeline-notes.md`.

## Scope
- **The repo root is both the git root and the Godot project root.** Run every command from here.
- **Nothing outside this repository is ever written**, except the session scratchpad under
  `<temp>/claude/`. Enforced by a hook, not by trust.
- Never push without explicit approval from the user. **Never push to `main`.**
- **Committing is `/begin`'s job and nobody else's.** It commits on a green review so the next
  session starts clean; every other command leaves the decision to the user.
- Make small, incremental changes. Stop for feedback rather than making large changes in
  one pass.

## Roles
- **Doer** — plans and implements changes. Runs tests 1–2.
- **Reviewer** — read-only *with respect to source*; never edits, writes or creates source
  files. Runs tests 1–6, judges the diff against the plan, approves or sends back.
- **modeller** (`/source-model`) — outside the loop. Finds CC0 assets and returns verified
  links. Never downloads, never launches the engine, never edits game code.

**`/source-model` and `/build` do not chain.** A manual download sits between them, so `/build`
has nothing to integrate until the files are on disk. Check that they are before spawning a
Doer at them.

## The loop
**`docs/roadmap.md` is the backlog and the state.** `/begin` runs the next session from it,
commits on approval, writes the result back and stops. Read it with
`.claude/scripts/roadmap.sh` — no launch. Use `/build <task>` for anything off the roadmap.

`.claude/commands/build.md` is the orchestrator's spec, and `/begin` follows it.
Send-backs go into the SAME Doer via SendMessage, so it keeps its context rather than
restarting cold. **An agent killed mid-run — usage limit, API error, stall watchdog — is
resumed the same way, never respawned cold.** Recover what it already bought from **disk** —
`git status --short` and the files it left, whose headers carry their own design contract —
then restate the brief *and what it already measured*, or it re-buys launches already paid
for. Its `.output` transcript (100k+ tokens — `offset` near the end, `limit` 3–4) answers only
what it *concluded* and never wrote down: open it when the artifacts do not, not by default.

## Learnings
A finding about the **pipeline** — not the game — goes in `.claude/learnings/` the moment it is
found, with the evidence for it; format and bar in `.claude/learnings/README.md`. Nothing filed
there is in force, and nothing is ever applied by the agent that filed it. `/consolidate` folds
the inbox, in a fresh session, with the user present.

**Most runs teach nothing. Zero entries is the normal, healthy outcome** — file on evidence,
never to have something to show.

## Budgets
Two counters, enforced by hooks: **12 agent turns** (spawns *and* SendMessage send-backs count)
and **40 engine launches**, the one that actually bites. Both are per **session** and never
reset, so **one `/build` per session**. On hitting either wall, stop and report. Do not raise
the ceiling.

**Read both with `.claude/scripts/budget.sh`** — the hooks' own counters, no launch spent, and
the only figure to report. Never tally your own launches, and never use `newest-log.sh count`:
one is arithmetic (an enumerated "8 of 40" measured **32**), the other is wall clock across
every session that ever ran.

## Guards
`.claude/settings.json` wires the PreToolUse hooks and the permission lists. A SessionStart
hook prints `GUARDS: armed (root …)`. **If that line is absent, the guards are off**, whatever
the config says.

Every guard names its own fix in the message it denies with. Two things they cannot tell you:

- The **write guard** walls Edit / Write / NotebookEdit to the repo and the scratchpad, but
  **does not see writes made through Bash** — a `>` redirect or `python -c` is opaque to it.
  That gap is covered by permissions.
- `settings.local.json` is deliberately **empty**. Never resolve a permission prompt with
  "always allow" — it writes an untracked rule there that no diff will ever show you. If a
  command deserves standing approval, add it to `settings.json` on purpose.

**Read files with the Read / Grep / Glob tools.** `cat`, `head`, `tail`, `grep`, `find` and
`sed -n` will prompt. When a prompt fires on `rm`, `cp`, `mv`, a `>` redirect or `python -c`,
the fix is usually **not** to approve it — it is to use **Edit** or **Write**, which are walled
by the write guard and never prompt.

**Binary files are the exception.** `Write` cannot copy a `.bin`, a `.png` or a `.glb`, so
moving a downloaded asset into the project is a real `cp` and a real prompt. Batch every copy
into **one** command.

---

## Environment

**Use the wrapper scripts in `.claude/scripts/`: `gd.sh` to launch the engine, `newest-log.sh`
to read logs, `diff.sh` to read everything changed since the last commit (staged or not),
`budget.sh` to read the budget counters.** All four are allowlisted and run without prompting,
and `gd.sh` is the only sanctioned way to start the engine — the raw binary path is no longer
allowlisted.

```bash
.claude/scripts/gd.sh --headless -- --harness-check-resources
.claude/scripts/newest-log.sh            # summary of the newest session log
```

`gd.sh` prints the HARNESS and error lines, then
`GD: exit=<code> script_errors=<n> log=<path>`, and exits with the **engine's** status. **Quote
that `log=` path for every launch you report.** Pass `--raw` for unfiltered output.
It resolves the `_console.exe` binary itself — the plain one does not attach stdout, so no
test can read output; override with `GODOT_BIN` if the install moves.

Session logs go to Godot's user data folder, **not** into the repo — one fresh
`session_*.log` per launch, never appended to:
```
/c/Users/dabha/AppData/Roaming/Godot/app_userdata/psychedelic tank game/logs/
```
That folder name is derived by Godot from `application/config/name` in `project.godot` and is
configured nowhere else. **Renaming the project without editing `newest-log.sh` makes it read
a different project's logs**, which exist and are well-formed. Change both or neither.

`newest-log.sh` takes `path`, `errors`, `fps`, `grep <pattern>`, or no argument for a summary;
`-n 2` reads the run *before* the last one.

---

## The dev harness

`autoloads/DevHarness.gd` is the supported way to ask the running game questions. It is inert
unless launched with a `--harness-*` argument after a bare `--`.

Every command prints `HARNESS: <cmd> PASS|FAIL {json}` to stdout, writes a `"test"` entry to
the session log, and **sets the exit code** (0 pass, 1 fail). Prefer branching on the exit code
over parsing text.

```bash
# Load every resource in the project and report any that fail
.claude/scripts/gd.sh --headless -- --harness-check-resources

# Read values off the live scene tree (names available: scene, tree, root).
# --harness-eval is REPEATABLE: batch every question into ONE launch. Each launch costs a
# full engine boot plus a terrain rebuild, so five questions asked separately cost five
# times what the same five cost batched.
.claude/scripts/gd.sh --headless -- --harness-eval="scene.chunks_total" --harness-eval="scene.terrain_triangles"

# Screenshot from an explicit camera pose "x,y,z:targetx,targety,targetz".
.claude/scripts/gd.sh -- --harness-shot=0,120,120:0,0,0 --harness-out=.claude/images/layout.png
```

`--harness-eval` resolves names against the scene tree and **cannot reach engine singletons**
(`Input`, `InputMap`, `OS`), so an input binding cannot be tested here at all. Call the branch
bodies directly on the live node instead and report the binding as unverified; do not build
input-synthesis scaffolding to close the gap.

**One launch runs one harness command.** The dispatch quits after whichever matched, so a
launch can mutate the scene *or* photograph it, never both in that order. **This bites carving
specifically**: `scene.terrain.carve(...)` and a screenshot of the hole are two launches, and
the eval that carves cannot show you the result.

**Within one eval batch, no frame runs.** Anything produced by `_process`, a `Timer` or a tween
is frozen at its pre-batch value, so emitting a signal and then reading a var that `_process`
mirrors returns the *pre-emit* number — indistinguishable from a signal that never fired. Read
off the node that owns the value.

It **can** read GDScript `const`s, which plain `get()` cannot — do not file a `const` under the
limit above by analogy. Arithmetic over them composes in the same batch, so retuning a constant
is a measurement rather than an unverifiable claim.
```
node.get_script().get_script_constant_map()["FORWARD_DRIVE"]
```

Screenshots go in `.claude/images/` — gitignored, and fenced by `.claude/.gdignore` so Godot
does not import the pngs as textures.

---

## Testing requirements

**This list is the single source of truth for the test sequence.** `doer.md` and `reviewer.md`
point here and deliberately do not restate the commands — when they did, they drifted, and the
stale copies were the ones the agents ran.

**Who runs what.** The Doer runs tests 1 and 2 only, catching its own mistakes before a review
cycle is spent on them. The Reviewer runs the whole sequence. Both running everything doubles
the cost and finds nothing the second pass would not.

1. **Compile test** — headless run, zero script errors:
   ```bash
   .claude/scripts/gd.sh --headless --quit-after 120
   ```
   Expect `script_errors=0` on the `GD:` summary line.

2. **Resource test** — every resource in the project resolves:
   ```bash
   .claude/scripts/gd.sh --headless -- --harness-check-resources
   ```
   Expect exit 0 and `check_resources PASS`. Never skip this because test 3 passed: a run only
   touches the resources the running scene needs, so a dead asset hides behind a green smoke
   test. Walk everything, don't sample.

   **It does not cover `.gltf`.** `DevHarness.CHECKED_EXTS` is `tscn/tres/gdshader/glb/glsl`,
   so a model shipping as `.gltf` + `.bin` + loose textures is invisible here. Do **not** add
   the extension — `_all_resource_paths()` walks directories itself and ignores `.gdignore`, so
   it would then load every staged copy. `preload()` the model instead of `load()`ing it at
   runtime, making it a compile-time dependency: a missing `.bin` or texture then fails **test
   1** instead of passing quietly.

3. **Runtime test** — headless run of the main scene, no errors in the log:
   ```bash
   .claude/scripts/gd.sh --headless --quit-after 300
   .claude/scripts/newest-log.sh
   ```
   `"event":"error"` and `"event":"script_error"` fail the run. `"event":"warning"` is reported,
   not failed on. **There is currently no expected-warning exception in this project** — a
   clean warning list is achievable, so treat any warning as worth naming rather than assuming
   it is background noise. Report each entry with its `message` and `stack`.

4. **Performance test** — windowed, waiting for samples rather than guessing a frame budget:
   ```bash
   .claude/scripts/gd.sh -- --harness-fps=10     # optional: --harness-fps-min=45
   ```
   Passes when the **worst** sample clears the floor (default 45), because a healthy average
   hides a one-second stall and the stall is the thing worth finding. Reports min/avg/max.
   **Ten samples, not five**: a new shader's first pipeline compile lands in the first sampled
   second and sets the minimum, reading as a large regression a re-run does not reproduce.
   Target 60 minimum, 120 ideal. Do **not** substitute `--quit-after N` plus a log grep — the
   old form, which could never pass.

   Windowed only; it refuses under `--headless`, where fps describes an idle renderer rather
   than the game. vsync caps the number at the monitor's refresh rate, so ~60 is a ceiling, not
   a measurement of headroom.

5. **Load time** — the `t` field on the `loading_complete` entry, printed by
   `.claude/scripts/newest-log.sh`. Flag above 30 seconds. Terrain meshing dominates it here,
   and it scales with `chunk_resolution` cubed — check that before blaming anything else.

6. **Visual check** — on any change to a shader, mesh, material, camera, light or UI, capture a
   **windowed** screenshot and answer one question: **does it render?** Present, not black, not
   inside-out, not invisible, not culled. Mechanical, with a right answer, and the failure class
   this project actually hits.

   Answer it by **measuring the pixels, not by looking**:
   ```bash
   .claude/scripts/gd.sh -- --harness-shot=0,120,120:0,0,0 --harness-out=.claude/images/layout.png
   python .claude/scripts/check_render.py .claude/images/layout.png
   ```
   Prints `RENDER: PASS|FAIL {json}` and sets the exit code. It catches gross failure — a black
   frame, a flat fill, a magenta missing-material wash, a no-contrast cleared buffer — and
   nothing subtler.

   To ask whether one specific thing is present, use region mode rather than a throwaway pixel
   script:
   ```bash
   python .claude/scripts/check_render.py shot.png --region 0.3,0.3,0.7,0.85 \
       --expect luma_mean '>' 12
   ```
   Coordinates are fractions of the frame; `--expect KEY OP VALUE` repeats and takes any
   numeric field, including `hue_frac.orange`.

   **Put every threshold between two measured numbers; never guess one** — better, pass the
   control as a second image: `--control before.png` measures the same boxes on it and adds a
   `delta.<key>` twin (subject minus control) to every field, so `--expect delta.luma_mean '<'
   -2` tests a difference instead of a guess.

   **A crater is the hard case, and it is this project's most common visual change.** It is a
   *hole*, so there is nothing new to find — the evidence is that terrain which was there is
   not. Shoot the same pose before and after and diff the crater's box; a fixed camera and a
   fixed seed make the before shot pixel-exact everywhere the shell did not land.

   **Judge on two channels, never one.** A shadowed slope and a hole into the void can share a
   `luma_mean`, and only hue separates them; against bright sky, only luma does. Call a region
   changed where it moves on **both**, and report both numbers.

   **A sweep resolves nothing finer than one column**, so size the column under the feature you
   are hunting: 96 columns across a 1920 band is 30 px a strip, and averaged a 14 px hole away.

   Report the path, and do NOT judge whether it looks *good*. **Never read the image back into
   context** — the `Read` guard denies it and its message explains why.

---

## Traps

Most of these were paid for in the parent project; the ones marked **(here)** were met in this
one. The post-mortems are in pipeline-notes.

- **Headless compiles no shaders**, so nothing is drawn. Every visual bug in the parent
  project's history was invisible headless and appeared only windowed. A headless-only pass
  does not mean the game looks right.
- **Close the Godot editor before an agent edits files.** With the project open, the editor
  re-saves resources from its own in-memory copy and silently overwrites on-disk changes,
  reverting paths and dropping `uid=` attributes. This has already destroyed a completed
  refactor.
- **`chunk.generate()` builds a collider; only `chunk.rebuild()` may be called twice.** (here)
  Meshing and collision are separate on purpose — the parent project's version always added a
  fresh `StaticBody3D` at the end of meshing, so re-running it on a carved chunk stacked a
  second collider on the first. Invisible in all six tests, and wrong in the way collision bugs
  are wrong. Carving goes through `Terrain.carve()`, which calls `rebuild()`.
- **Fence a downloaded asset pack before Godot ever walks it.** Packs ship the same models as
  glTF *and* FBX *and* OBJ, and Godot imports all of them — 68 models arrive as ~300 import
  records. Drop a `.gdignore` in the staging folder **before the next engine launch or editor
  open**, then copy only what you need into a feature folder. `assets/incoming/.gdignore`
  already exists; keep it.
- **`.godot/` holds absolute paths** and goes stale after any move or rename. Symptom:
  `Failed loading resource:` naming a path no tracked file contains any more. Fix: delete
  `.godot/` and re-run `--headless --import`. The game may still *run* in this state, so a
  smoke test will not show it.
- **`--quit-after` counts frames, not seconds.** A long load hitch can consume the budget
  before a timer fires. Prefer a generous frame count over a tight one.
- **`--check-only --script X.gd` does not load autoloads.** It reports false
  `Identifier not found: GameEvents` for any script using a singleton. Use a real headless run
  as the compile gate — which has its own: **a new `class_name` is not resolvable by any other
  script until an import pass**, so test 1 reports `Could not find type` on a correct file. Run
  `--headless --import` once after adding one; `gd.sh` says so when it sees that error.
- **Measure, don't assume.** Most real defects here have been wrong *numbers*, not crashes. Use
  `--harness-eval` to check a claimed value rather than trusting a description of it. **But a
  statistic computed by the change under review is not independent evidence for the property it
  names** — re-reading it is a re-execution, not a check. `craters_carved` is exactly this
  shape: it is incremented by the carve. Confirm against the pixels, or against a quantity
  derived differently — for generated geometry, `mesh.get_aabb()` plus the node transform, and
  the surface's vertex count, both of which read back **non-empty headless** on a procedural
  `ArrayMesh`.
- **When a change moves a resource reference, the evidence is the reference** —
  `resource_path` or `get_script().resource_path` off the live object, never a number derived
  from it. A null-guarded assignment falling back to a default-constructed object yields
  *identical* numbers wherever the authored `.tres` matches the script's `@export` defaults, so
  an equality gate passes a change that never took effect. Unlike the trap above the statistic
  is independent — both paths simply compute the same one.

---

## Logging
State, performance, error and test events all go to the session log (NDJSON, one object per
line, one fresh file per run); types are `state`, `perf`, `error`, `test`. Read the newest file
via `newest-log.sh`, and do not rely on stdout unless the log is unavailable.
`autoloads/ErrorCapture.gd` captures runtime errors, warnings and script errors automatically —
including ones no code anticipated — so a clean error grep is meaningful.

## Code standards
- Suggest improvements to architecture, maintainability, clarity and readability following
  Godot/GDScript/C# best practices, but do not apply large refactors without approval.
- Follow existing project conventions; do not introduce a new pattern for a problem an existing
  convention already covers.
- Cross-system events go through the `GameEvents` bus. A parent talking to its own child stays
  a plain signal — routing that through a global bus hides a local relationship.
- **Collision layers are load-bearing and easy to get silently wrong.** Layer 1 is terrain,
  layer 2 is the tank, layer 3 is projectiles. A shell that does not mask terrain flies through
  the world; a shell that masks itself detonates on the barrel. Re-measure `collision_layer`
  and `collision_mask` on any new physics body rather than reading the intent off the diff.

## Out of scope for now (do not build without explicit request)
- Automated visual diffing / SSIM thresholds
- Branch strategy automation
- Additional agent roles beyond Doer / Reviewer / modeller
- **Automated asset downloading.** `curl`, `wget` and `Invoke-WebRequest` are denied on purpose.
  The modeller flags a link and the user fetches it by hand; do not add a fetcher.
- GPU/compute marching cubes. The CPU implementation is the one that works; a Godot 3-era
  compute sketch exists in `../procedural-landscapes` and does not run. See pipeline-notes.
- Scoring, win conditions. This is a mechanics prototype. (**Enemy tanks came off this list on
  2026-08-30** at the user's request — they are roadmap S4c. Scoring and win conditions did not.)
