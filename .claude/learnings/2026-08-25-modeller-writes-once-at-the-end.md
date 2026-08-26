# The modeller writes its candidates file only at the very end, so an interruption loses the whole run

- date: 2026-08-25
- surfaced-by: user session (not a `/build`)
- run: `/source-model` for a player tank, during session A of the foundation plan
- target: agent-file

**Evidence.** The first modeller run spent **63,484 subagent tokens across 56 tool uses over ~29
minutes** (1,749,972 ms), searching and WebFetch-verifying candidates. It was killed by an API
error at the exact moment its last output read *"All verified. Writing the shortlist."*

Immediately afterwards, `git status --short` showed only an unrelated `docs/` folder, and
`assets/incoming/` contained only `.gdignore`. **`player-tank.candidates.json` did not exist.**
Every one of those 56 verifications existed solely in the agent's context.

Resuming it via `SendMessage` (per `CLAUDE.md` § The loop) recovered the run for **74,580 tokens
and 2 tool uses** — no re-searching, no re-fetching. The rule works. But the resume was only
possible because the agent was resumable; had the context been lost rather than the agent
interrupted, ~29 minutes of verified page fetches would have been unrecoverable.

**What it suggests.** `modeller.md`'s Output section reads "Write `assets/incoming/…json` … Then
report back" — one write, composed after all verification is complete. Appending each candidate
to the file **as it is verified** would cap the loss of an interruption at one candidate instead
of the whole run.

**The tension worth handing to the consolidator, not resolving here.** An incrementally written
file is indistinguishable from a finished one, and a truncated shortlist that looks complete is
its own failure — the orchestrator would print four candidates as if they were five. Any fix
needs a completeness marker (a `.partial` suffix until done, or a sentinel field), which is a
schema change to the one artifact `source-model.md` calls "the seam a different search backend
plugs into later". That seam is deliberately stable, so this may be judged not worth the churn.

Note also that this cost is **not** visible to the budget counters: `/source-model` spends zero
engine launches, so a lost run is invisible to the one counter `CLAUDE.md` says actually bites.
