# --harness-eval cannot read a const off a class_name script with no live instance

- date: 2026-08-30
- surfaced-by: reviewer
- run: /begin S2 — strip the Wild Metal Country combat scaffolding
- target: claude.md

**Evidence.** `CLAUDE.md § The dev harness` states the harness "can read GDScript `const`s, which
plain `get()` cannot", with the example `node.get_script().get_script_constant_map()["FORWARD_DRIVE"]`.
That works only where a live node carries the script. `entities/CollisionLayers.gd` is a
`class_name` constant holder that is deliberately never instantiated, and both routes to it fail:

    --harness-eval="CollisionLayers.PLAYER_SHELLS"
      ERROR: Invalid named index 'CollisionLayers' for base type Object
    --harness-eval="load(\"res://entities/CollisionLayers.gd\").get_script_constant_map()"
      ERROR: On call to 'load':

(logs session_20260830_105556_362.log and session_20260830_105637_366.log). `DevHarness._cmd_eval`
parses with `expr.parse(source, ["scene","tree","root"])` and executes against `self`, so only those
three names, Variant utility functions and methods on DevHarness resolve — global script classes do
not, and neither does `load`. The second launch was spent solely on discovering the workaround also
fails.

**What it suggests.** `CLAUDE.md § Code standards` tells the Reviewer to "re-measure
`collision_layer` and `collision_mask` ... rather than reading the intent off the diff", but the
*reserved* bits (`PLAYER_SHELLS`, `ENEMY_SHELLS`) are reserved precisely because no body carries
them, so there is no live node to measure and the constant itself is out of reach. The only
available evidence is derived: the OR of layer and mask across every live body masked against the
reserved bits (`(tank.collision_layer | tank.collision_mask) & 20 = 0`), plus a source read. Worth
one clause in § The dev harness saying the const trick needs an instance, and one in § Code
standards saying reserved bits are verified by absence across live bodies, not by reading the
constant.
