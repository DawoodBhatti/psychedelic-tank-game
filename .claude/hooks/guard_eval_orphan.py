"""PreToolUse hook on Bash: refuse a --harness-eval that constructs a node and
cannot free it.

`--harness-eval` runs through `Expression`, which evaluates ONE expression.
There is nowhere to bind a temporary and nowhere to sequence a `free()`, so
anything the expression instantiates is orphaned for the life of the process -
and Godot reports orphaned RIDs at exit, into the session log.

Why that is worth a wall rather than a line in CLAUDE.md
-------------------------------------------------------
The leak does not look like a leak. It looks like a GAME defect, in the exact
place the pipeline goes looking for one: CLAUDE.md test 3 fails the run on
`"event":"error"` in the session log, and these arrive as errors.

Measured 2026-08-27. Verifying `shell.gd`'s `hit_mask` needs a live Shell and
the project has none at load, so the Doer read it with

    scene.tank.shell_scene.instantiate().hit_mask

That returns the right number - and left RID-leak errors in
session_20260827_122612_354.log. The Doer then had to argue in its report that
the errors were its own probe rather than the change under review; the
orchestrator had to pre-empt the attribution in the Reviewer's brief; and
without that paragraph the Reviewer would have spent a launch deciding whether
the game leaked. The cost of the trap is not the leak, it is the argument about
whose leak it is - and that argument is paid by whoever reads the log next.

The fix, and why it is strictly better
--------------------------------------
Go through the game's own construction path, which parents the object and hands
its lifetime to the tree. `scene.tank.fire()` does exactly that
(`get_parent().add_child(shell)`), and the value is then readable off the tree:

    --harness-eval='scene.tank.fire()'
    --harness-eval='scene.get_child(scene.get_child_count() - 1).hit_mask'

Measured on session_20260827_123141_365.log: `hit_mask` = 1, `shells_fired` = 1,
`errors=0 warnings=0`, no leak lines - on a launch that also freed 17 entities
through a second `scatter()`. Same answer, no leak, no attribution argument.
It also tests the path the game actually uses, which reading a fresh instance
never did.

Scope, and what this does NOT catch
-----------------------------------
`instantiate(` only. It is a `PackedScene` method and always yields a Node, so
a bare one in an eval always leaks: no false positives to trade against.

`.new()` is deliberately NOT matched. Most `.new()` calls in an eval are
RefCounted (`RandomNumberGenerator`, `Expression`, any Resource) and free
themselves, so matching the text would deny correct expressions to catch a case
nobody here has hit yet. If a `Node.new()` leak is ever actually measured, that
is an inbox entry with evidence, not a guess made now.

An `instantiate()` wrapped in `add_child(...)` is allowed: it is parented, so
the tree owns it and it dies with the scene.
"""
import hooklib


def call_end(text, at):
    """Index of the `)` closing the call whose `(` is at or after `at`.

    Returns -1 if the parens never balance. Quotes are tracked so a paren
    inside "a)b" is not counted.
    """
    depth = 0
    quote = ""
    i = at
    while i < len(text):
        ch = text[i]
        if quote:
            if ch == "\\":
                i += 2
                continue
            if ch == quote:
                quote = ""
        elif ch in "\"'":
            quote = ch
        elif ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1


def spans(text, needle):
    """(start, end) of every `needle(...)` call, end being its closing paren."""
    found = []
    at = 0
    while True:
        at = text.find(needle, at)
        if at < 0:
            return found
        end = call_end(text, at + len(needle) - 1)
        if end < 0:
            return found
        found.append((at, end))
        at = end


def offenders(command):
    """Every instantiate() in `command` that nothing parents."""
    parented = spans(command, "add_child(")
    bad = []
    at = 0
    while True:
        at = command.find("instantiate(", at)
        if at < 0:
            return bad
        if not any(start < at < end for start, end in parented):
            # Enough of the expression to be recognisable in the message.
            line = command[max(0, at - 60):at + len("instantiate()")]
            bad.append(line.lstrip("'\" ="))
        at += len("instantiate(")


def main():
    command = hooklib.command(hooklib.read_payload())
    if "--harness-eval" not in command:
        return

    bad = offenders(command)
    if not bad:
        return

    hooklib.deny(
        "Refused: this --harness-eval instantiates a node it cannot free.\n\n"
        "  ...%s\n\n"
        "Expression evaluates ONE expression - there is no way to bind a temp "
        "or sequence a free() - so the instance is orphaned, and Godot writes "
        "RID-leak errors at exit into the SAME session log that test 3 fails "
        "the run on. The next reader cannot tell your probe from a real "
        "defect, and has to spend a launch or an argument finding out.\n\n"
        "Call the game's own construction path instead, which parents the "
        "object and hands its lifetime to the tree, then read the value off "
        "the tree:\n"
        "  --harness-eval='scene.tank.fire()'\n"
        "  --harness-eval='scene.get_child(scene.get_child_count() - 1).hit_mask'\n\n"
        "If you genuinely must build one, parent it in the same expression: "
        "add_child(...instantiate())." % "\n  ...".join(bad))


if __name__ == "__main__":
    main()
