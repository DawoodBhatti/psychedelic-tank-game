"""PreToolUse hook on Bash: refuse a --harness-eval whose find_child cannot
find anything.

`Node.find_child(pattern, recursive = true, owned = true)` returns only nodes
whose `owner` is set, and **owner is set by scene instantiation and the editor,
by nothing else.** This level is built entirely in code - main.gd does
`Terrain.new()` then `add_child(terrain)`; terrain.gd's `_build_chunks`
does `add_child(chunk)` - and neither sets `owner`. So every
node in the running level has `owner == null`, and a defaulted find_child
returns null against a scene containing exactly what was asked for.

That makes this the dangerous shape of wrong. Not a failure - a **vacuous
pass**. "no crater exists anywhere" and "the terrain is full of craters"
both print `= <null>`, so the report reads identically either way and no test
in the sequence can tell them apart. A remembered rule is the weakest possible
answer to a failure mode that is invisible in its own output.

Hence a wall instead. Fires only on --harness-eval commands, and only on a
find_child / find_children whose `owned` argument is not literally `false`.

  find_child("Tank", true, false)                    -> allowed
  find_children("*Chunk*", "", true, false)            -> allowed
  find_child("Tank")                                 -> denied
  find_child("Tank", true)                           -> denied
  find_child("Tank", true, true)                     -> denied

Godot 4 signatures, and the argument that matters:
  find_child(pattern, recursive = true, owned = true)             -> arg 3
  find_children(pattern, type = "", recursive = true, owned = true) -> arg 4
"""
import hooklib

OWNED_INDEX = {"find_child": 2, "find_children": 3}


def split_args(text, start):
    """Top-level comma split of the call whose '(' is at `start`.

    Returns (args, end) or (None, -1) if the parens never balance. Tracks
    quotes so a comma inside "a,b" is not counted as a separator.
    """
    depth = 0
    quote = ""
    args = []
    current = ""
    i = start
    while i < len(text):
        ch = text[i]
        if quote:
            if ch == "\\":
                current += text[i:i + 2]
                i += 2
                continue
            if ch == quote:
                quote = ""
            current += ch
        elif ch in "\"'":
            quote = ch
            current += ch
        elif ch in "([{":
            depth += 1
            if depth == 1:
                current = ""
            else:
                current += ch
        elif ch in ")]}":
            depth -= 1
            if depth == 0:
                args.append(current)
                return args, i
            current += ch
        elif ch == "," and depth == 1:
            args.append(current)
            current = ""
        else:
            current += ch
        i += 1
    return None, -1


def offenders(command):
    """Every defaulted find_child/find_children call in `command`."""
    found = []
    for name, owned_at in OWNED_INDEX.items():
        needle = name + "("
        at = 0
        while True:
            at = command.find(needle, at)
            if at < 0:
                break
            # `find_children(` also contains `find_child` + "ren(", never
            # `find_child(`, so the two names cannot shadow each other here.
            args, end = split_args(command, at + len(name))
            at = end if end > at else at + len(needle)
            if args is None:
                continue
            if len(args) <= owned_at or args[owned_at].strip() != "false":
                found.append(name + "(" + ",".join(args) + ")")
    return found


def main():
    command = hooklib.command(hooklib.read_payload())
    if "--harness-eval" not in command:
        return

    bad = offenders(command)
    if not bad:
        return

    hooklib.deny(
        "Refused: this --harness-eval cannot find anything, whatever is in "
        "the scene.\n\n  %s\n\n"
        "find_child defaults to owned = true, and nothing in this level has "
        "an owner - it is built in code with add_child(), and only scene "
        "instantiation and the editor set owner. So this returns null "
        "against a scene that contains exactly what you are looking for, "
        "and an absence check written this way passes vacuously.\n\n"
        "Pass owned = false:\n"
        "  find_child(\"Name\", true, false)\n"
        "  find_children(\"Pattern*\", \"\", true, false)" % "\n  ".join(bad))


if __name__ == "__main__":
    main()
