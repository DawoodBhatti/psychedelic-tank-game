"""PreToolUse hook on Agent and SendMessage: bounds Doer/Reviewer round trips.

This is the LOOP guard - it catches a pair that will not converge. It is NOT
the cost guard: a single agent can spend an hour inside one spawn, which is
what count_godot_launches.py is for. Two failure modes, two counters.

It counts SendMessage as well as Agent, because the loop it is supposed to
bound does not run on Agent. `build.md` deliberately carries Reviewer feedback
back into the SAME Doer via SendMessage, so the Doer keeps its context instead
of restarting cold - which meant the send-back half of every round trip was
invisible to the guard. Rounds were bounded only incidentally, by the Reviewer
being re-spawned each time. A turn is a turn; both cost a model call.

The budget written in prose is a promise - a model that loses count simply
carries on. This makes it a wall: the count lives on disk, the check runs in
the harness, and the model gets no vote.
"""
import os

import hooklib

LIMIT = int(os.environ.get("CLAUDE_AGENT_BUDGET", "12"))


def main():
    payload = hooklib.read_payload()
    used = hooklib.Counter("agent-turns", payload.get("session_id")).add()

    if used > LIMIT:
        hooklib.deny(
            "Iteration budget spent: %d agent turns (spawns + send-backs) "
            "already used this session, limit %d (CLAUDE.md). Stop now and "
            "report status for the user to assess. Do not raise the ceiling. "
            "This is a per-SESSION budget: if the task genuinely needs more, "
            "start a fresh session rather than continuing in this one."
            % (used - 1, LIMIT))


if __name__ == "__main__":
    main()
