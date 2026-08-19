"""PreToolUse hook on Bash: refuse a command whose PREFIX breaks the allow list.

Permission rules match command TEXT. `Bash(python .claude/scripts/*)` clears a
bare `python .claude/scripts/check_render.py img.png --region 0.4,0.4,0.6,0.6`
silently - and does not clear the same call once it is wrapped in

    cd "C:/Users/.../psychedelic-tank-game" 2>/dev/null; IMG=shot.png; python ...

Nothing about the allow list needs to change for that command; the command
broke its own match. One run's Reviewer prefixed `cd` five times and stopped
for seven approvals, none of which the allow list had refused.

CLAUDE.md carried the rule in prose for some time ("do not decorate a command,
and do not prefix it with `cd`"), and a fold responded to a miss by moving the
prose closer to where the thought happens. It was missed again anyway, five
times in one run. A rule that has to be remembered is the weakest kind, so this
became a wall instead - and the 2026-08-14 compression pass then deleted the
paragraph, deliberately. This message is now the only place the rule is taught,
which is why it has to name the fix rather than just refuse.

Scope: the FIRST top-level statement only, which is what a prefix is. That is
also what keeps this safe to run on every Bash call - the first statement of a
heredoc write is `cat <<EOF`, never a `cd`, so nothing legitimate is caught by
a `cd` sitting in a payload somewhere.

  cd /repo && python .claude/scripts/check_render.py x.png   -> denied
  IMG=x.png; python .claude/scripts/check_render.py "$IMG"    -> denied
  python .claude/scripts/check_render.py x.png                -> allowed
  GODOT_BIN=/c/other/godot.exe .claude/scripts/gd.sh --headless -> allowed

The last one matters: an inline `VAR=value cmd` env prefix is the documented
escape hatch for a moved engine install. It still prompts (its text starts with
GODOT_BIN), but prompting is not denying, and taking it away would remove the
only way to point gd.sh somewhere else. Only an assignment used as a *separate
statement* is refused - that form exists to be referenced as `"$VAR"` later,
which is exactly the substitution no pattern can see through.
"""
import re

import hooklib

ASSIGN = re.compile(r"^[A-Za-z_]\w*=")


def first_statement(command):
    """The command text up to the first unquoted `;`, `&&` or `||`.

    Tracks quotes and paren depth so a separator inside "a;b" or $(a && b) is
    not mistaken for the end of the statement.
    """
    quote = ""
    depth = 0
    i = 0
    while i < len(command):
        ch = command[i]
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
        elif depth == 0:
            if ch == ";":
                return command[:i]
            if command[i:i + 2] in ("&&", "||"):
                return command[:i]
        i += 1
    return command


def rest_after_assignment(statement):
    """What follows `VAR=value` in `statement`, or None if it is not one.

    Returns "" when the statement is nothing but the assignment - the form
    that is refused. A non-empty rest is an inline env prefix on a real
    command, which is allowed.
    """
    if not ASSIGN.match(statement):
        return None
    quote = ""
    depth = 0
    i = statement.index("=") + 1
    while i < len(statement):
        ch = statement[i]
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
        elif ch.isspace() and depth == 0:
            # `VAR=$(cmd arg)` is one value; the space inside the substitution
            # does not end it.
            return statement[i:].strip()
        i += 1
    return ""


def offence(command):
    """(kind, statement) for a decorated prefix, or None."""
    statement = first_statement(command).strip()
    if not statement:
        return None
    if re.match(r"cd(\s|$)", statement):
        return "cd", statement
    rest = rest_after_assignment(statement)
    if rest == "":
        return "assignment", statement
    return None


REASONS = {
    "cd": (
        "Refused: this command leads with `cd`.\n\n  %s\n\n"
        "The working directory is already the repository root, so the `cd` "
        "changes nothing except the command's TEXT - and permission rules "
        "match text. `Bash(.claude/scripts/*)` and "
        "`Bash(python .claude/scripts/*)` clear these calls silently until a "
        "prefix breaks the match, at which point the same harmless command "
        "stops for an approval nobody's allow list was withholding."),
    "assignment": (
        "Refused: this command leads with a bare variable assignment.\n\n"
        "  %s\n\n"
        "It exists to be referenced as \"$VAR\" further along, and a "
        "substitution is not resolvable from command text, so every call "
        "after it prompts. Permission rules match text.\n\n"
        "Write the value out at each use site. If it is needed often enough "
        "for that to hurt, that is a feature for a script under "
        ".claude/scripts/ - which is allowlisted as a whole, tracked in git, "
        "and visible in a diff."),
}

TAIL = ("\n\nIssue the command plainly, with no prefix. To set an environment "
        "variable for one command, put it inline: `VAR=value cmd args`.")


def main():
    found = offence(hooklib.command(hooklib.read_payload()))
    if not found:
        return

    kind, statement = found
    hooklib.deny((REASONS[kind] % statement) + TAIL)


if __name__ == "__main__":
    main()
