# A hand-ticked `_physics_process(dt)` integrates dt but MOVES one frame's worth

- date: 2026-08-31
- surfaced-by: reviewer
- run: /begin S4c - the red tanks: patrol, aggro, leash
- target: claude.md

**Evidence.** `move_and_slide()` takes no delta: it uses the engine's own frame delta, so a
hand-called `_physics_process(0.0166)` advances velocity and rotation by 16.6 ms and the
transform by whatever the last frame took. Measured directly in one eval batch: with
`velocity = (0,0,-20)` a single bare `move_and_slide()` moved a live EnemyTank
614.2324 -> 614.0777 on z = **0.1547 units = 7.7 ms**, not the 0.333 units 1/60 would give and
not the dt anyone passed. Consequence in this session: 40 hand ticks on a tank displaced 200
units from its patrol centre moved it 200.0 -> 199.9992 (Doer's own run: 299.9999 -> 298.008,
2 units of the 190 needed), while `speed` climbed to 6.7 m/s and yaw swung the full 93° that
0.66 s of TURN_RATE predicts. The motion and the integration disagree by the ratio of the
passed dt to the real frame time, which is machine- and framerate-dependent.

**What it suggests.** The harness section already says no frame runs inside an eval batch and
blesses calling branch bodies directly on the live node. It should add that hand-ticking is
NOT a substitute for elapsed simulation: velocity, rotation, timers and accumulators advance
at the dt you pass, the transform does not, so any gate phrased as "it gets there" or "it
comes back" cannot be closed this way at all - and a gate phrased as "N physics frames" is
sampling a shorter journey than its name. Read the decision (`_steer_target()` returning the
centre, the sign of the radial velocity) rather than the arrival.
