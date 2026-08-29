# --harness-eval cannot assign, and the failure reads as "the flag is never used"

- date: 2026-08-28
- surfaced-by: doer
- run: /build destructible flag + 2x world widen
- target: claude.md

**Evidence.** One launch, five expressions, log
`session_20260828_135637_478.log`:

    scene.terrain.destructible = true       -> {"error":"Expected '='"}
    scene.terrain.destructible              -> false
    scene.terrain.set('destructible', true) -> <null>
    scene.terrain.destructible              -> true
    GameEvents.shell_exploded.get_connections().size() -> 2

`Expression` parses one expression, so `=` never parses. The batch then CARRIES
ON and every later read reports the pre-write value - here `false` - which is
indistinguishable from a flag nothing consults. The error text "Expected '='"
reads like a typo complaint about the `=` you did write, so the natural next move
is to go hunting in the game code for a flag that is fine.

`Object.set('prop', value)` is a call, parses, and DOES run the GDScript setter -
proven by the connection count moving to 2 in the same batch.

**What it suggests.** One line in CLAUDE.md's harness section, next to the
existing "cannot reach engine singletons" note: `--harness-eval` is read-only
syntactically; mutate through `node.set("prop", value)` or a method call, which
run setters. This is the pattern any "prove the flag is actually read" task needs,
and CLAUDE.md currently supplies only the signal-emit half.
