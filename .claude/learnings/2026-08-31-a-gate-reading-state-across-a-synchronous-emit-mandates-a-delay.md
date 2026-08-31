# A gate clause that reads state across a synchronous emit silently mandates a delay

- date: 2026-08-31
- surfaced-by: orchestrator
- run: /begin S4b - shells that hurt, and a tank that can die
- target: notes            # roadmap-gate authoring; possibly begin.md

**Evidence.** S4b's gate said "the player survives two direct hits and dies on the third
(`alive` reads true, true, false)". A correct implementation of everything else the section
asked for reads **true, true, true**: `_on_destroyed()` emits `level_reset_requested`,
`main.gd` calls `tank.respawn()` inside that same call, and `alive` is back before the caller
returns. The section separately, and rightly, insisted death route into the reset path
`death_height` already uses - so the emit is synchronous by instruction.

The Doer closed the gap by adding `@export var death_reset_delay = 1.6`, a dial the roadmap
never asked for, and said plainly it was needed for the gate to read as written. The Reviewer
judged it legitimate on independent game-feel grounds (an instant teleport is not a death to a
player either) and confirmed the fall path is byte-for-byte HEAD's - but also recorded that
setting the dial to **0 returns the gate to true/true/true with no code change**. So the gate
does not test "the tank dies on the third hit"; it tests "the tank dies on the third hit *and
stays dead longer than one call frame*", and only the first half was written down.

**What it suggests.** Gates are authored ahead of the code, and a clause that samples a
variable across a synchronous emit -> handler -> mutate round-trip is a constraint on the
implementation's *timing*, not just its behaviour. Either say so in the section (name the
delay as a dial the way S4b named the 3:1 toughness ratio), or write the clause against
something the round-trip does not restore - a destroyed signal count, `damageable.is_alive`
sampled inside the handler, a respawn counter. Worth a line wherever gate-writing guidance
lives, because the failure is silent in both directions: the Doer invents an unrequested dial,
or a correct implementation looks like it failed.
