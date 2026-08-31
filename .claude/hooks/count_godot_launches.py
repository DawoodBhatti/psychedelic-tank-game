"""PreToolUse hook on Bash: bounds how many times the game is launched.

The agent-spawn counter bounds the LOOP - Doer and Reviewer failing to
converge. It does not bound what happens inside a single pass, and that turned
out to be where the cost actually is: one /build run reported "2 of 25
iterations" while spending 70 tool calls and roughly 45 engine launches.

An iteration that means anything is "change something, test it". A Godot launch
is the closest mechanically countable proxy for the test half, and it is also
the expensive half - each one boots the engine, rebuilds the level, and returns
output that has to be read back.

Counting an INVOCATION, not the word "Godot"
--------------------------------------------
The first version matched /Godot_v[\\w.-]*\\.exe|\\bgodot4?\\b/ anywhere in the
command. That charged a launch for reading a log file, because this project's
logs live in

    ~/AppData/Roaming/Godot/app_userdata/psychedelic tank game/logs/

and reading the newest log is the single most frequent thing the Reviewer does.
`ls -1 .../Godot/.../logs/*.log | tail -1` cost one engine launch. So the cost
guard billed the cheapest operation in the pipeline and would hit its wall
early, citing a number that was not real. A brake you cannot trust is worse
than no brake, because the run gets planned around a wrong figure.

A launch now has to look like an invocation: the binary at a command position -
the start of the string, or after a separator, `do`/`then`, or a `timeout N`
wrapper. The project's habit of `GD="<path>"; ... "$GD" --headless` is resolved
too, by noting which variables were assigned the binary.

`.claude/scripts/gd.sh` counts as a launch, because it is one
--------------------------------------------------------------
The wrapper exists so the allow list has a stable command to approve, instead
of trying to pattern-match a shell program (`cd`, `GD="..."`, `"$GD"`, a pipe
into grep) that it structurally cannot see through. But the wrapper hides the
binary from THIS hook, which reads command text - so without the case below the
cost guard would silently count zero from the day the wrapper landed, and the
budget everyone plans around would quietly stop being real.

This is why `gd.sh` is the only script permitted to launch the engine, and why
it launches exactly once per invocation. A test sequence is several `gd.sh`
calls, not one script that loops internally: several calls are several matches
here, and the count stays honest without this file having to model anything.

Known undercount, accepted: a `for` loop that launches the engine once per file
counts as one occurrence, not one per iteration. Detecting that would mean
evaluating the loop. The counter is a brake, not an accountant.

A denied command boots nothing, so it is not billed
---------------------------------------------------
Four other PreToolUse hooks sit on the same `Bash` matcher, and three of them
can DENY. A hook cannot see another hook's verdict, and the increment here was
already written by the time the deny won - so every refused `gd.sh` call left
the counter one high, permanently, and silently: the denial message said nothing
about it and `budget.sh` reads this same number. Measured three times, most
recently on 2026-08-31, where one engine boot moved the count by two.

The fix is not ordering (which cannot work) and not a PostToolUse move (which
needs an event nobody here has confirmed fires). Each denying guard now answers
`would_deny(command)` as a plain function, and this hook asks them the same
question they are about to answer themselves. It reads the guard list out of
settings.json rather than keeping its own copy, for the reason check_guards.py
does: a list of things to check that can drift from the real one is a check that
passes while the thing it checks is broken. A guard added later needs only a
`would_deny`; one that lacks it is skipped, and the count stays as it was.

Failure is open in the EXPENSIVE direction on purpose: any error reading the
settings, importing a guard or calling its predicate falls through to counting.
An uncounted launch is a budget that lies low, which is the failure this whole
file exists to prevent.
"""
import json
import os
import re
import sys

import hooklib

LIMIT = int(os.environ.get("CLAUDE_GODOT_LAUNCH_BUDGET", "40"))

# Start of string, after a separator or subshell, or after a loop/if keyword.
CMD_POS = r"(?:^|[;&|(]\s*|\n\s*|\bdo\s+|\bthen\s+|\belse\s+)"
# `timeout 90 <binary>` still launches the engine.
WRAPPER = r"(?:timeout\s+[\d.]+[smhd]?\s+)?"
# The console binary by path (quoted or not), or the bare name on PATH.
BINARY = (r"[\"']?[^\s\"';|&]*Godot_v[\w.\-]*\.exe[\"']?"
          r"|godot4?(?:\.exe)?\b")
# The wrapper, with or without an explicit `bash`. Only matched at a command
# position, so `cat .claude/scripts/gd.sh` still costs nothing.
WRAPPER_SCRIPT = r"(?:bash\s+)?[\"']?(?:\./)?\.claude/scripts/gd\.sh\b"

# `GD="/c/.../Godot_v4.7-..._console.exe"` - remember GD, so that a later
# `"$GD" --headless` is recognised as the launch it is.
ASSIGN = re.compile(r"\b([A-Za-z_]\w*)=[\"']?[^\s\"';|&]*Godot_v[\w.\-]*\.exe",
                    re.IGNORECASE)


def count_launches(command):
    alternatives = [BINARY, WRAPPER_SCRIPT]
    names = sorted({m.group(1) for m in ASSIGN.finditer(command)})
    if names:
        alternatives.append(r"[\"']?\$\{?(?:%s)\}?[\"']?"
                            % "|".join(re.escape(n) for n in names))
    pattern = re.compile(
        CMD_POS + WRAPPER + r"(?:" + r"|".join(alternatives) + r")",
        re.IGNORECASE)
    return sum(1 for _ in pattern.finditer(command))


HERE = os.path.dirname(os.path.abspath(__file__))
SETTINGS = os.path.join(HERE, "..", "settings.json")
DISPATCH = re.compile(r"run\.sh\s+([A-Za-z_]\w*)")


def bash_guards():
    """Every hook settings.json wires onto a matcher that includes `Bash`."""
    with open(SETTINGS, encoding="utf-8") as handle:
        matchers = (json.load(handle).get("hooks") or {}).get("PreToolUse") or []

    names = []
    for matcher in matchers:
        if "Bash" not in str(matcher.get("matcher", "")):
            continue
        for hook in matcher.get("hooks") or []:
            found = DISPATCH.search(str(hook.get("command", "")))
            if found and found.group(1) != "count_godot_launches":
                names.append(found.group(1))
    return names


def refused_elsewhere(command):
    """Will another guard on this matcher deny this command outright?

    Asked before the counter commits, because a denied call never reaches the
    engine. Any failure answers False, so an unanswerable question costs a
    launch rather than hiding one.
    """
    try:
        if HERE not in sys.path:
            sys.path.insert(0, HERE)
        for name in bash_guards():
            guard = __import__(name)
            verdict = getattr(guard, "would_deny", None)
            if verdict is not None and verdict(command):
                return True
    except Exception:
        return False
    return False


def main():
    payload = hooklib.read_payload()

    command = hooklib.command(payload)
    launches = count_launches(command)
    if launches == 0 or refused_elsewhere(command):
        return

    counter = hooklib.Counter("godot-launches", payload.get("session_id"))
    used = counter.read()

    if used >= LIMIT:
        hooklib.deny(
            "Engine-launch budget spent: %d of %d used this session. Each "
            "launch boots Godot and rebuilds the level, so this is the real "
            "cost of a run. Stop and report status. If you were asking "
            "several questions one at a time, note that --harness-eval "
            "REPEATS: batch them into a single launch instead." % (used, LIMIT))

    used = counter.add(launches)

    # Reported on EVERY launch, not only near the wall. This counter is keyed
    # by session id and written here, so it is the only per-session launch
    # count in the pipeline that is not a guess - and saying it at the moment
    # of the launch puts it in front of the agent that made it, which is the
    # one that otherwise reaches for `newest-log.sh count` and reports a
    # wall-clock figure as a per-session one. An orchestrator then copies that
    # into the run summary, which is where the user reads it.
    #
    # hooklib.context is a warning that does not vote on the call; see the note
    # there on why that matters. The batching advice still waits for 0.75, so a
    # long pass can change tactics before it is cut off.
    advice = ("" if used < int(LIMIT * 0.75) else
              " Batch --harness-eval expressions into one launch where you can.")
    hooklib.context("Engine launches this session: %d of %d. This is the "
                    "authoritative count - report this number.%s"
                    % (used, LIMIT, advice))


if __name__ == "__main__":
    main()
