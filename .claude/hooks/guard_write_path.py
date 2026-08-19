"""PreToolUse hook on Edit/Write/NotebookEdit: refuse to write outside the repo.

CLAUDE.md says to stay inside the project, but prose is a promise - an agent
that misreads a path simply writes to it. This makes it a wall: the check runs
in the harness, on the resolved absolute path, and the model gets no vote.

Scoped to the whole REPOSITORY, deliberately. The pipeline's own configuration
(CLAUDE.md, .claude/agents, .claude/hooks) sits alongside the game and has to
stay editable. The property worth guaranteeing is "nothing outside this
checkout is ever modified", which is the one that protects the rest of the
machine.

Symlinks are resolved before comparison, so a link pointing out of the repo
cannot be used as a way around the check.

The session scratchpad is allowed too, and that is a fix rather than a
loophole. The harness hands every session a scratch directory under
<temp>/claude/ and tells it to put temporary files there; this hook used to
deny it. An agent following its instructions hit a wall, and the cheapest way
round a wall on Edit is a Bash redirect or `python -`, which prompts, which
gets answered with "always allow" - writing a permanent broad rule into
settings.local.json. That is not hypothetical: it is exactly how
`Bash(python -)` got itself standing approval in this project. A guard that
forces work onto the one path it cannot see is worse than one with a door in
it.
"""
import os
import tempfile

import hooklib

# The repo root is the directory this hook file lives two levels below:
#   <repo>/.claude/hooks/guard_write_path.py
REPO = os.path.realpath(os.path.join(os.path.dirname(__file__), "..", ".."))

# The harness's own scratch area. Temporary by construction and outside any
# project, so writes here modify nothing that matters.
SCRATCH = os.path.realpath(os.path.join(tempfile.gettempdir(), "claude"))

PATH_KEYS = ("file_path", "path", "notebook_path")


def within(path, root):
    """True if `path` is `root` or sits beneath it.

    commonpath rather than startswith: a sibling directory whose name merely
    begins with the root's name (…/psychedelic-tank-game-backup) is NOT inside
    it. ValueError means different drives on Windows - definitively outside.
    """
    try:
        return os.path.commonpath([path, root]) == root
    except ValueError:
        return False


def main():
    target = hooklib.tool_input(hooklib.read_payload(), *PATH_KEYS)
    if not target:
        return

    # Relative paths are relative to the working directory, which is the repo.
    if not os.path.isabs(target):
        target = os.path.join(REPO, target)

    resolved = os.path.realpath(target)

    if not (within(resolved, REPO) or within(resolved, SCRATCH)):
        hooklib.deny(
            "Refused: %s is outside the repository (%s). CLAUDE.md restricts "
            "all edits to this checkout. Temporary files belong in the session "
            "scratchpad under %s, which is allowed. If the file genuinely "
            "needs to change, ask the user to do it."
            % (resolved, REPO, SCRATCH))


if __name__ == "__main__":
    main()
