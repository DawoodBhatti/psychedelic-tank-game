"""Shared plumbing for every hook in this directory.

Three things had been copied between hooks often enough to drift, which is the
same argument that produced run.sh one layer down: one copy cannot drift from
itself.

  1. `json.load(sys.stdin)` inside a bare try/except. Every guard here FAILS
     OPEN by design - a hook that cannot parse its input, or crashes, must
     never block work - and that property was re-implemented in eight files
     rather than guaranteed in one.
  2. The PreToolUse response shape. Six hooks hand-built the same
     `hookSpecificOutput` dict. The rule that a warning must use
     `additionalContext` and NOT `permissionDecision: "allow"` - because
     "allow" bypasses the permission prompt outright, which silently approved
     every command crossing the threshold - had to be learned and commented
     twice, in two files, because the shape was written out twice.
  3. The per-session counter. Three hooks sanitised a session id, made a temp
     directory, read an int and wrote one back, in three directories under
     three function names.

Hooks are launched as `python <abs>/<name>.py`, so the interpreter puts this
directory on sys.path and a plain `import hooklib` resolves. A test that loads
a hook via importlib.spec_from_file_location must add the directory itself.

This file is a single point of failure for every guard, so check_guards.py
verifies it is present at session start - the same trade, and the same answer,
as the run.sh dispatcher.
"""
import json
import os
import sys
import tempfile

# One root for every piece of per-session hook state, so the counters are
# findable together instead of scattered across three sibling directories.
STATE_ROOT = os.path.join(tempfile.gettempdir(), "claude-pipeline")


def read_payload():
    """The hook's stdin JSON, or exit 0.

    Fail-open lives here. Every caller's first line is this, and none of them
    should be deciding independently what to do with unreadable input.
    """
    try:
        return json.load(sys.stdin)
    except Exception:
        sys.exit(0)


def command(payload):
    """The Bash command text this hook was fired on, or ""."""
    return str((payload.get("tool_input") or {}).get("command", "") or "")


def tool_input(payload, *keys):
    """The first non-empty value among `keys` in tool_input, or None."""
    fields = payload.get("tool_input") or {}
    for key in keys:
        if fields.get(key):
            return str(fields[key])
    return None


def _emit(event, **fields):
    print(json.dumps({"hookSpecificOutput": dict(hookEventName=event, **fields)}))
    sys.exit(0)


def deny(reason, event="PreToolUse"):
    """Refuse the call outright. The reason is what the model reads, so it must
    name the fix - every guard here is expected to teach at the point of
    failure rather than rely on a paragraph somebody remembered."""
    _emit(event, permissionDecision="deny", permissionDecisionReason=reason)


def ask(reason, event="PreToolUse"):
    """Force a permission prompt even where an allow rule would clear it.
    Used where a human's answer IS the mechanism, as with `git push`."""
    _emit(event, permissionDecision="ask", permissionDecisionReason=reason)


def context(message, event="PreToolUse"):
    """Say something without voting on the call.

    NOT `permissionDecision: "allow"`: a PreToolUse hook returning any
    permissionDecision overrides the prompt, so a warning sent that way
    approves whatever command happened to trigger it. A warning must not
    decide.
    """
    _emit(event, additionalContext=message)


class Counter:
    """An integer kept per session, on disk, for the budget hooks.

    Keyed by session_id and never reset, which is deliberate: these are SESSION
    budgets, not per-task ones. Two /build runs in one session share them.
    """

    def __init__(self, name, session_id):
        sid = "".join(c for c in str(session_id or "")
                      if c.isalnum() or c in "-_")[:64]
        folder = os.path.join(STATE_ROOT, name)
        os.makedirs(folder, exist_ok=True)
        self.path = os.path.join(folder, sid or "nosession")

    def read(self):
        """The stored value, or 0. Unreadable state counts as no state: a
        corrupt counter must not block work any more than a crashed hook."""
        try:
            with open(self.path) as handle:
                return int(handle.read().strip() or 0)
        except Exception:
            return 0

    def write(self, value):
        with open(self.path, "w") as handle:
            handle.write(str(value))

    def add(self, amount=1):
        """Increment and return the new total."""
        total = self.read() + amount
        self.write(total)
        return total
