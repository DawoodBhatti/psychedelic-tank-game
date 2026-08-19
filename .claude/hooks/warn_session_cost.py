"""PreToolUse: say out loud when a session has become expensive per turn.

The measured finding this exists for, from session 36e74bb7 of this project:

  1085 API requests in one session. Context grew monotonically from 36k to
  950k and was NEVER reclaimed. 553M input tokens processed, 108M effective.
  The last tenth of the session ran at ~834k context per request against 88k
  for the first tenth - so the same question asked late cost roughly ten times
  what it cost early.

Everything else is a rounding error against that. Subagents were 2.7% of total
spend. Images were 10%. Session length was the rest, and it compounds: the
cost of turn N is paid again on turns N+1..end.

The remedy is trivial and nobody does it, because there is no signal - a long
session feels exactly like a short one from the inside. So: emit one. This is
the same reasoning as every other guard here (prose is a promise, a hook is a
wall), except that this one deliberately does NOT block. Cutting off a run
mid-task to save tokens would cost more than it saves; the user decides when
to stop, and this makes sure they know they should be deciding.

Reads only the tail of the transcript, so it stays cheap on a 30MB file.
Fires once per threshold per session, not on every call.
"""
import json
import os

import hooklib

# Thresholds in context tokens, with what to do about each.
STEPS = (
    (300000, "This session is past 300k of context. Every turn from here "
             "re-reads all of it before anything new happens."),
    (500000, "Past 500k. A turn now costs roughly six times what it cost at "
             "the start of the session, for the same work."),
    (700000, "Past 700k. This is the expensive end of the curve. Unless you "
             "are mid-task, finishing here and starting fresh is the single "
             "largest saving available."),
)

TAIL_BYTES = 262144


def context_size(transcript):
    """Current context = what the last request had to read back."""
    try:
        size = os.path.getsize(transcript)
        with open(transcript, "rb") as f:
            if size > TAIL_BYTES:
                f.seek(size - TAIL_BYTES)
                f.readline()          # discard a partial line
            lines = f.read().decode("utf-8", "replace").splitlines()
    except Exception:
        return 0

    for line in reversed(lines):
        line = line.strip()
        if not line or '"usage"' not in line:
            continue
        try:
            usage = (json.loads(line).get("message") or {}).get("usage") or {}
        except Exception:
            continue
        if usage:
            return (usage.get("cache_read_input_tokens", 0)
                    + usage.get("cache_creation_input_tokens", 0))
    return 0


def main():
    payload = hooklib.read_payload()

    transcript = payload.get("transcript_path")
    if not transcript or not os.path.exists(transcript):
        return

    size = context_size(transcript)
    if size < STEPS[0][0]:
        return

    # The counter stores the highest threshold already announced, so each step
    # fires once. A warning on every tool call is noise that gets ignored.
    latch = hooklib.Counter("session-cost", payload.get("session_id"))
    reported = latch.read()

    step = None
    for threshold, message in STEPS:
        if size >= threshold > reported:
            step = (threshold, message)

    if step is None:
        return

    latch.write(step[0])

    hooklib.context(
        "SESSION COST: context is now ~%dk tokens. %s\n"
        "Run /usage for the breakdown. Note that images already read "
        "cannot be removed - only a fresh session clears them."
        % (size // 1000, step[1]))


if __name__ == "__main__":
    main()
