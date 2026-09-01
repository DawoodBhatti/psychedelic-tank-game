# A landed note's "you get X for free" is an inference, and the next brief carries it as a measurement

- date: 2026-08-31
- surfaced-by: orchestrator
- run: /begin S4c - the red tanks: patrol, aggro, leash
- target: notes

**Evidence.** S4c's "What S4b left you" block contained: "**Widening `hit_mask` gives enemies
splash for free.** `Shell`'s blast target set is filtered by `hit_mask` rather than a second
list, so adding `ENEMIES` to the mask makes red tanks splashable with nothing else to
remember." That is a derivation from code shape - note the "so" - written in the same bolded
register as the measured facts beside it in the same block (`kill_heal` **20.0**, `hit_mask`
**33**, `death_reset_delay` **1.6 s**), all of which S4b's Reviewer had actually read off live
nodes. It is false: `intersect_shape()` does not report `CharacterBody3D` under Jolt, measured
independently by both the Doer and the Reviewer this run (0 damageables at an enemy's origin
and at its hull centre, 1 at a tower's).

The distance from note to code was short. `/begin` requires the roadmap section be handed to
the Doer verbatim, so I copied the claim into the brief unexamined; the Doer wrote two comments
in `tank/shell.gd` asserting it, which then had to be corrected before the commit. Had the gate
depended on splash rather than on a direct hit, the session would have been built on it.

**What it suggests.** `build.md` already says to check the arithmetic of a plan's **locked**
rows before writing the brief, because "a locked row is an unverified claim wearing a
decision's clothes". This is the same failure one step later in the pipeline: a *landed* note's
"for free" / "with nothing else to remember" / "needs no new code" clause is the same shape -
an unverified claim wearing a **measurement's** clothes, and harder to spot because it sits in
a block where every neighbouring number was genuinely measured. Two candidate fixes, and the
consolidator should pick: require landed notes to mark inferences as inferences (S4b's own
"also noted" line did exactly this - "check it on a tank hull... before authoring"), or add the
orchestrator's pre-flight duty to grep a handover's load-bearing "for free" clauses for a
measurement behind them. The second costs one grep; the first costs nothing but depends on
every future Reviewer keeping the discipline.
