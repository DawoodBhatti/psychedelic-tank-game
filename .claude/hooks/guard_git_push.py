"""PreToolUse hook on Bash: makes two CLAUDE.md rules mechanical.

  "never push to main"                        -> hard deny, no override
  "never push without explicit user approval" -> force a permission prompt

The second returns "ask" rather than allowing, because a prompt IS the approval
mechanism - and it fires even if a broad Bash(...) allow rule would otherwise
let a push through silently.

Matches on command text rather than a permission-rule prefix, so a push buried
in a compound command is still caught.

Each `git push` invocation is isolated from its neighbours and its flags are
dropped, so what gets tested is the DESTINATION of each refspec: the part after
`:`, less a leading `+`, less any `refs/heads/` prefix. `--all` and `--mirror`
are denied from any branch, because they push main whatever is checked out.

Testing the whole command string instead - the first version - was wrong in
both directions, missing four ways of reaching main and denying a `main` that
belonged to a neighbouring command. All four are regression cases in
test_guard_git_push.py; the post-mortem is in pipeline-notes.md.
"""
import os
import re
import subprocess
import sys

import hooklib

REPO = os.path.realpath(os.path.join(os.path.dirname(__file__), "..", ".."))

# Heredoc bodies are part of the command string but are DATA, not commands. A
# commit message written via `git commit -F - <<'EOF' ... EOF` that happens to
# mention a push inside a compound command would otherwise be read as a real
# push and blocked - which is exactly what happened when this hook was first
# committed: it blocked the commit that introduced it.
HEREDOC_START = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")

# Must look like an actual invocation - at the start of the command or after a
# separator - not merely the words appearing inside a string.
INVOCATION = re.compile(r"(?:^|[;&|(]\s*|\n\s*)git\s+push\b")

# Where this invocation's arguments stop and the next command begins.
ARG_END = re.compile(r"[;&|)\n]")

PROTECTED = {"main", "master"}

# Push every branch, so they reach main from any checkout.
BROAD = {"--all", "--mirror"}

# Flags that consume the following token, which must not be read as a refspec.
VALUE_FLAGS = {"-o", "--push-option", "--repo", "--receive-pack", "--exec"}


def strip_heredocs(s):
    """Remove heredoc bodies, keeping the command scaffolding around them."""
    out = []
    pos = 0
    while True:
        m = HEREDOC_START.search(s, pos)
        if not m:
            out.append(s[pos:])
            return "".join(out)
        out.append(s[pos:m.end()])
        marker = m.group(2)
        term = re.compile(r"^\s*" + re.escape(marker) + r"\s*$", re.M)
        t = term.search(s, m.end())
        if not t:
            # Unterminated heredoc: drop the remainder rather than scan data.
            return "".join(out)
        pos = t.end()


def invocations(cmd):
    """The argument text of each `git push` in the command, in order."""
    found = []
    for m in INVOCATION.finditer(cmd):
        rest = cmd[m.end():]
        end = ARG_END.search(rest)
        found.append(rest[:end.start()] if end else rest)
    return found


def tokens(argtext):
    return [t.strip("\"'") for t in argtext.split()]


def positionals(toks):
    """Non-flag arguments: the remote, then any refspecs."""
    args = []
    skip = False
    literal = False
    for t in toks:
        if skip:
            skip = False
            continue
        if not literal and t == "--":
            literal = True
            continue
        if not literal and t.startswith("-"):
            if t in VALUE_FLAGS:
                skip = True
            continue
        args.append(t)
    return args


def destination(refspec):
    """The ref a refspec writes to: `HEAD:refs/heads/main` -> `main`."""
    dest = refspec.split(":")[-1].lstrip("+")
    return dest.rsplit("/", 1)[-1]


def current_branch():
    """What is checked out. Half of what this guard does depends on it:
    `git push origin` is routine from a feature branch and forbidden from main.

    Resolved here rather than in the shell wrapper, and `-C REPO` rather than
    trusting the cwd. The wrapper used to do it, which meant a `git branch`
    subprocess on EVERY Bash tool call; this runs only once a push is actually
    present. argv[1] overrides, which is how the tests supply a branch.
    """
    if len(sys.argv) > 1 and sys.argv[1]:
        return sys.argv[1]
    try:
        return subprocess.run(
            ["git", "-C", REPO, "branch", "--show-current"],
            capture_output=True, text=True, timeout=5).stdout.strip()
    except Exception:
        return ""


def main():
    pushes = invocations(strip_heredocs(hooklib.command(hooklib.read_payload())))
    if not pushes:
        return

    branch = current_branch()

    for argtext in pushes:
        toks = tokens(argtext)

        broad = BROAD.intersection(toks)
        if broad:
            hooklib.deny(
                "Blocked: `git push %s` pushes every branch, including main. "
                "CLAUDE.md forbids pushing to main under any circumstance."
                % sorted(broad)[0])

        # args[0] is the remote; anything after it is a refspec.
        refspecs = positionals(toks)[1:]

        hit = [r for r in refspecs if destination(r) in PROTECTED]
        if hit:
            hooklib.deny(
                "Blocked: this push targets main/master (refspec %r). "
                "CLAUDE.md forbids pushing to main under any circumstance."
                % hit[0])

        if not refspecs and branch in PROTECTED:
            hooklib.deny(
                "Blocked: `git push` with no refspec while on '%s' pushes "
                "main/master. CLAUDE.md forbids this." % branch)

    hooklib.ask("CLAUDE.md requires explicit user approval before any git "
                "push. Approve to continue, or decline.")


if __name__ == "__main__":
    main()
