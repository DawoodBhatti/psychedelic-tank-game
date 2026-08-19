"""Feeds cases to the decoration guard without putting them in a shell command,
so testing the guard cannot be blocked by the guard itself.

    python test_guard_bash_decoration.py .claude/hooks/run.sh

This guard sits on every Bash call, so the cases that must stay ALLOWED are the
important half. A false positive here blocks ordinary work, and the guard's
whole claim is that the commands it refuses had a plain form that already ran.
"""
import json
import subprocess
import sys

RUNNER = sys.argv[1] if len(sys.argv) > 1 else ".claude/hooks/run.sh"

REPO = 'C:/Users/dabha/Documents/game dev/codebase/psychedelic-tank-game'
CHECK = 'python .claude/scripts/check_render.py .claude/images/shot.png'

# (label, command, expected)
CASES = [
    # The seven prompts from the run that produced this guard.
    ("cd + && chain",
     'cd "%s" && %s' % (REPO, CHECK), "deny"),
    ("cd + ; chain",
     'cd "%s" 2>/dev/null; %s' % (REPO, CHECK), "deny"),
    ("cd alone",
     'cd "%s"' % REPO, "deny"),
    ("cd relative",
     'cd .claude/images && ls', "deny"),
    ("bare assignment then use",
     'IMG=.claude/images/shot.png; python .claude/scripts/check_render.py "$IMG"',
     "deny"),
    ("quoted assignment with spaces",
     'IMG="a b.png"; ls "$IMG"', "deny"),
    ("assignment by substitution",
     'LOG=$(.claude/scripts/newest-log.sh path); ls "$LOG"', "deny"),
    ("cd then assignment then command",
     'cd "%s"; IMG=x.png; %s' % (REPO, CHECK), "deny"),

    # Allowed: the plain forms that were available all along.
    ("plain check_render", CHECK, "allow"),
    ("plain gd.sh", ".claude/scripts/gd.sh --headless --quit-after 120", "allow"),
    ("plain git diff", "git diff -- player/player.gd", "allow"),
    ("two plain calls chained", "ls .claude/images && %s" % CHECK, "allow"),
    ("repeated region flags",
     CHECK + " --region 0.4,0.4,0.6,0.6 --region 0.05,0.46,0.13,0.54", "allow"),

    # Allowed: the inline env prefix. It prompts, but it is the documented way
    # to point gd.sh at a moved install, so it must not be denied.
    ("inline env prefix",
     'GODOT_BIN=/c/other/godot_console.exe .claude/scripts/gd.sh --headless',
     "allow"),

    # Not a prefix, so not this guard's business. The first statement is what
    # decides, which is what keeps a heredoc payload out of scope.
    ("cd inside a quoted payload",
     'echo "cd somewhere; then run it"', "allow"),
    ("separator inside quotes",
     'echo "a; b" && ls', "allow"),
    ("cd later in the chain",
     'ls && cd .claude/images', "allow"),
    ("heredoc mentioning cd",
     "cat <<'EOF' > .claude/learnings/x.md\ncd is the thing\nEOF", "allow"),
    ("word starting with cd",
     "ls cdrom/", "allow"),
    ("path containing cd",
     "ls .claude/scripts/cd.sh", "allow"),
    ("empty command", "", "allow"),
]

fails = 0
for label, cmd, expected in CASES:
    p = subprocess.run(["bash", RUNNER, "guard_bash_decoration"],
                       input=json.dumps({"tool_input": {"command": cmd}}),
                       capture_output=True, text=True)
    body = p.stdout.strip()
    got = json.loads(body)["hookSpecificOutput"]["permissionDecision"] if body else "allow"
    ok = "OK  " if got == expected else "FAIL"
    if got != expected:
        fails += 1
    print("  %s %-32s expected=%-5s got=%s" % (ok, label, expected, got))

print("\n%d/%d passed" % (len(CASES) - fails, len(CASES)))
sys.exit(1 if fails else 0)
