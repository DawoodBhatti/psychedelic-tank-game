"""SessionStart hook: prove the guards are loaded, or say plainly that they are not.

A hook that is absent fails silently, and a session with every guard off looks
exactly like a session where nothing was violated. So: announce arming. If the
`GUARDS: armed` line is missing from the context, the guards are off, whatever
the config says.

Four questions that can still go wrong:

  1. Is this session rooted where settings.json actually is? Claude Code loads
     settings.json from the working directory only, while CLAUDE.md traverses
     upward - so a session started elsewhere can display every rule while
     enforcing none. (See pipeline-notes.md; the repo used to have two
     plausible roots and this was a real, silent failure.)
  2. Are the shared files there? Every hook dispatches through run.sh and
     imports hooklib, so either one missing disarms all of them at once. That
     is the trade for not having eight copies of the same wrapper and the same
     stdin/deny boilerplate drift apart.
  3. Is there an interpreter for the hooks to run in? A wrapper that cannot
     start is treated by the harness as a non-blocking error - the guard is
     off, and nothing is said.
  4. Has anything crept back into settings.local.json? That file is untracked
     and invisible in review, and "always allow" writes to it. This project has
     already had `Bash(python -)` - arbitrary code from stdin, straight past
     the write guard - acquire standing approval that way.

The list of hooks to check is READ OUT OF settings.json, never kept here. It
used to be a literal tuple of filenames, which is a copy of someone else's
list: adding a hook without editing this file produced a guard nobody verified,
and removing one produced a permanent false "missing" at every session start. A
checker whose list of things to check can drift from the real one is a checker
that passes while the thing it checks is broken.
"""
import json, os, re, shutil, sys

REPO = os.path.realpath(os.path.join(os.path.dirname(__file__), "..", ".."))
HOOKS = os.path.join(REPO, ".claude", "hooks")
SETTINGS = os.path.join(REPO, ".claude", "settings.json")

# Files every hook depends on: the dispatcher settings.json invokes, and the
# module they all import.
SHARED = ("run.sh", "hooklib.py")

# `bash .claude/hooks/run.sh <name>` -> <name>
DISPATCH = re.compile(r"run\.sh\s+([A-Za-z_]\w*)")


def registered_hooks():
    """Every hook name settings.json actually wires up, in sorted order."""
    try:
        with open(SETTINGS, encoding="utf-8") as f:
            events = json.load(f).get("hooks") or {}
    except Exception:
        return []

    names = set()
    for matchers in events.values():
        for matcher in matchers:
            for hook in matcher.get("hooks") or []:
                found = DISPATCH.search(str(hook.get("command", "")))
                if found:
                    names.add(found.group(1) + ".py")
    return sorted(names)


def local_overrides():
    """Any allow/deny rules sitting in the untracked settings.local.json."""
    path = os.path.join(REPO, ".claude", "settings.local.json")
    try:
        with open(path, encoding="utf-8") as f:
            perms = json.load(f).get("permissions") or {}
    except Exception:
        return []
    return (perms.get("allow") or []) + (perms.get("deny") or [])


def main():
    lines = []
    cwd = os.path.realpath(os.getcwd())

    if cwd != REPO:
        lines.append(
            "GUARDS: UNKNOWN ROOT. This session started in %s, not the repo "
            "root %s, so .claude/settings.json is not guaranteed to have "
            "loaded. Treat the write wall, the push guard and both budget "
            "counters as OFF until verified." % (cwd, REPO))
    elif not os.path.isfile(os.path.join(REPO, ".claude", "settings.json")):
        lines.append(
            "GUARDS: OFF. No .claude/settings.json at %s, so no PreToolUse "
            "hook is registered." % REPO)
    else:
        lines.append("GUARDS: armed (root %s)." % REPO)

    for shared in SHARED:
        if not os.path.isfile(os.path.join(HOOKS, shared)):
            lines.append(
                "GUARDS: OFF. %s is missing from %s. Every hook needs it, so "
                "all of them fail open at once." % (shared, HOOKS))

    registered = registered_hooks()
    if not registered:
        lines.append(
            "GUARDS: no hooks registered in %s, or it could not be read. "
            "Nothing is being enforced." % SETTINGS)

    missing = [h for h in registered
               if not os.path.isfile(os.path.join(HOOKS, h))]
    if missing:
        lines.append(
            "GUARDS: %d hook script(s) registered in settings.json but missing "
            "from %s: %s. A hook whose script is absent fails open - it "
            "enforces nothing." % (len(missing), HOOKS, ", ".join(missing)))

    if not (shutil.which("python") or shutil.which("python3")):
        lines.append(
            "GUARDS: no python on PATH. Every hook wrapper exits 0 without "
            "running its check, so all guards are effectively OFF.")

    overrides = local_overrides()
    if overrides:
        lines.append(
            "GUARDS: settings.local.json carries %d permission rule(s) that "
            "are untracked and invisible in review: %s. These were almost "
            "certainly added by answering a prompt with 'always allow'. Move "
            "anything that deserves standing approval into settings.json, and "
            "empty this file."
            % (len(overrides), ", ".join(repr(o) for o in overrides[:5])))

    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": "\n".join(lines),
    }}))


if __name__ == "__main__":
    main()
