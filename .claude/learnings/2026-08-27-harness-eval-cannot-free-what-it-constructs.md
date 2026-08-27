# --harness-eval cannot free what it constructs, and the leak looks like a game defect

- date: 2026-08-27
- surfaced-by: reviewer
- run: /build session D — entity layer + scatter (re-review)
- target: claude.md

**Evidence.** Verifying `shell.gd`'s `hit_mask` needs a live Shell, and the project has none at
load. The Doer read it with `scene.tank.shell_scene.instantiate().hit_mask`. That works and
returns the right number, but `Expression` evaluates one expression with no way to bind a temp
or sequence a `free()`, so the instance is orphaned — and Godot printed RID-leak errors at exit
into `session_20260827_122612_354.log`, the same session log CLAUDE.md test 3 says to fail the
run on. The Doer had to argue the errors were its own probe; the orchestrator had to pre-empt
the attribution in the reviewer's brief; without that paragraph the reviewer would have spent a
launch distinguishing "my probe leaked" from "the game leaks".

The working alternative is to go through the game's own construction path, which parents the
object and hands its lifetime to the tree. `scene.tank.fire()` does exactly that
(`get_parent().add_child(shell)`), and the value is then readable off
`scene.get_child(scene.get_child_count() - 1)`. Measured on that launch
(`session_20260827_123141_365.log`): `hit_mask` = 1, `shells_fired` = 1, and the log reports
`errors=0 warnings=0` with no leak lines — on a launch that also freed 17 entities through a
second `scatter()`. Same answer, no leak, no attribution argument.

**What it suggests.** CLAUDE.md § The dev harness already enumerates the eval limits it knows
about — no engine singletons, no frame runs inside a batch, consts are readable. This one
belongs beside them: an eval expression that constructs a node orphans it, and the resulting
exit-time leak lands in the session log as something indistinguishable from a real defect.
Prefer calling the game's own method that parents the object; `preload`/`instantiate` inside an
eval is the form to avoid.
