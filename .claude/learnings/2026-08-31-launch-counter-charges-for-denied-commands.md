# The engine-launch counter charges a launch for a command another guard then refuses

- date: 2026-08-31
- surfaced-by: reviewer
- run: /begin S4 — Destructible towers
- target: hook

**Evidence.** A `--harness-eval` batch containing `scene.tank.shell_scene.instantiate().hit_mask`
was denied by the orphan-node guard. The PreToolUse counter had already fired: the fps run before
it reported "Engine launches this session: 14 of 40", the refused command reported "15 of 40" with
no `GD:` summary and no engine output, and the corrected retry reported "16 of 40". The log
directory confirms nothing booted — `session_20260831_080820_458.log` (fps) is followed directly by
`session_20260831_081258_317.log` (the retry), with no file in the four-minute gap. One engine boot
occurred across a counter movement of two.

**What it suggests.** The counter increments on the *attempt*, so every guard denial on a `gd.sh`
command inflates the budget that "actually bites" by one, and the inflation is invisible — the
denial message says nothing about it, and `budget.sh` is explicitly the only figure agents are
allowed to report, so no one can correct for it. Either the counter hook should run after the
denial hooks (or skip when the call is refused), or a denied `gd.sh` should say so in its message
so the reader knows the number ahead of them is one high. The bar for filing this is that the
budget is the binding constraint on a session and this is a silent overcharge on it, not a
rounding detail.
