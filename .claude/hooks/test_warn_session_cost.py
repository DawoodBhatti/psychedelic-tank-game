"""Tests for warn_session_cost.py.

The three properties that matter: it must fire ONCE per threshold (a warning on
every tool call is noise that gets ignored), it must never block, and it must
not DECIDE - a PreToolUse hook returning `permissionDecision` at all, "allow"
included, overrides the permission prompt. A warning carries context; it does
not vote.

Run:  python .claude/hooks/test_warn_session_cost.py
"""
import json, os, subprocess, sys, tempfile, uuid

HERE = os.path.dirname(os.path.abspath(__file__))
HOOK = os.path.join(HERE, "warn_session_cost.py")


def transcript_with(context_tokens):
    path = os.path.join(tempfile.gettempdir(), "cost_test_%s.jsonl" % uuid.uuid4().hex[:8])
    with open(path, "w", encoding="utf-8") as f:
        f.write(json.dumps({"message": {"role": "user", "content": "hi"}}) + "\n")
        f.write(json.dumps({"message": {"role": "assistant", "content": [],
                                        "usage": {"cache_read_input_tokens": context_tokens,
                                                  "cache_creation_input_tokens": 0,
                                                  "output_tokens": 10}}}) + "\n")
    return path


def fire(transcript, session):
    payload = json.dumps({"session_id": session, "transcript_path": transcript,
                          "tool_name": "Bash", "tool_input": {"command": "ls"}})
    out = subprocess.run([sys.executable, HOOK], input=payload, capture_output=True,
                         text=True).stdout.strip()
    if not out:
        return None
    return json.loads(out)["hookSpecificOutput"]


def run():
    failures = []
    sid = "costtest-" + uuid.uuid4().hex[:8]
    state = os.path.join(tempfile.gettempdir(), "claude-session-cost", sid)

    def check(label, got, want):
        if got != want:
            failures.append("%s: expected %s, got %s" % (label, want, got))

    # Quiet below the first threshold.
    check("below 300k stays silent", fire(transcript_with(120000), sid) is None, True)

    # Fires on crossing.
    r = fire(transcript_with(350000), sid)
    check("350k fires", r is not None, True)
    if r:
        check("350k never decides", "permissionDecision" in r, False)
        check("350k names the size", "~350k" in r.get("additionalContext", ""), True)

    # Same threshold again in the same session: silent.
    check("no repeat at same threshold", fire(transcript_with(360000), sid) is None, True)

    # A higher threshold fires once more.
    r = fire(transcript_with(750000), sid)
    check("750k fires", r is not None, True)
    if r:
        check("750k never decides", "permissionDecision" in r, False)
    check("no repeat at 750k", fire(transcript_with(760000), sid) is None, True)

    # A missing transcript must not crash or block.
    check("missing transcript is silent", fire("/no/such/file.jsonl", sid) is None, True)

    try:
        os.remove(state)
    except OSError:
        pass

    for f in failures:
        print("FAIL " + f)
    print("\n%d checks, %d failed" % (9, len(failures)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(run())
