# A stale .godot/ after a DELETION has no symptom - it passes tests 1 and 2 green

- date: 2026-08-30
- surfaced-by: orchestrator (Doer flagged it in its report)
- run: /begin S2 — strip the Wild Metal Country combat scaffolding
- target: claude.md

**Evidence.** `CLAUDE.md § Traps` documents `.godot/` going stale and names its symptom:
"`Failed loading resource:` naming a path no tracked file contains any more." That is the
**move/rename** case. S2 was a deletion, and the deletion case is silent.

After removing `entities/enemy_body.gd`, `guardian_placeholder.tscn`, `prop_placeholder.tscn` and
`profiles/guardian_hull.tres`, the Doer ran the compile and resource gates against the stale
cache and both were green:

    test 1  GD: exit=0 script_errors=0                      (session_20260830_104448_365.log)
    test 2  check_resources PASS {"checked":9,"failed":[]}   (session_20260830_104459_360.log)

while `.godot/global_script_class_cache.cfg` still registered `EnemyBody` →
`res://entities/enemy_body.gd`, and `.godot/filesystem_cache10` still recorded `valley.tres`
depending on both deleted `.tscn`s. No `Failed loading resource:` was ever emitted, by either
gate. After `rm -rf .godot` + `--headless --import`, a grep of `.godot` for
`enemy_body|EnemyBody|guardian|prop_placeholder` returns no matches, and both tests are green
again — indistinguishable from the green they gave over the stale cache.

The Doer only caught this because it went looking on its own initiative. Nothing in the test
sequence asks the question, and the trap as written would not have prompted it: the reader is
told to watch for a failure that does not occur here.

**What it suggests.** Two candidate shapes, and the consolidator should pick one rather than
both. Either the trap's wording grows a deletion clause — *a stale cache after a delete does not
announce itself; rebuild on any session that removes a tracked resource, do not wait for a
symptom* — or the check becomes mechanical, since it is a grep over `.godot` for the paths the
diff deleted and costs no engine launch. The mechanical version is the one that does not depend
on an agent choosing to look.
