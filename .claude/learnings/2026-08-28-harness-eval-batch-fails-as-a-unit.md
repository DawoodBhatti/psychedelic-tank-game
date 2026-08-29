# A --harness-eval batch fails as a unit, so one bad expression reds out 47 good measurements

- date: 2026-08-28
- surfaced-by: reviewer
- run: /build lose destructible terrain by default; widen the glen 2x
- target: claude.md

**Evidence.** A 50-expression batch in one launch
(`log=.../logs/session_20260828_140810_367.log`) returned 47 correct values and 3 errors —
`Invalid named index 'world_size' for base type Object`, from addressing `field.ground`
(an `SDFComposite`) instead of `field.ground.layers[0]`. The launch ended
`HARNESS: eval FAIL {"count":50,...}` and `GD: exit=1 script_errors=0`. The 47 good
values, including every collision-layer and invariant reading the review turned on, were
sitting in the same stdout.

CLAUDE.md § The dev harness says "Prefer branching on the exit code over parsing text."
Followed literally on a batch, that discards the launch and re-buys it — out of the counter
that bites. The two rules interact the wrong way round: the same section says "batch every
question into ONE launch", and the harder you batch, the more expressions a single typo
takes down with it.

**What it suggests.** The exit-code guidance holds for single-command harness runs and
inverts for repeatable `--harness-eval`, where the code is the AND over every expression.
Worth one sentence saying so, and saying that the per-expression `HARNESS: eval  <expr> = <value>`
lines are the result — a red batch is a list to read, not a launch to repeat. The JSON
already carries per-expression `error` keys, so nothing in the harness needs changing.
