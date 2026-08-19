"""Feeds cases to the vacuous-eval guard without putting them in a shell
command, so testing the guard cannot be blocked by the guard itself.

    python test_guard_vacuous_eval.py .claude/hooks/run.sh

The interesting cases are the ones that must stay ALLOWED: this guard sits on
every Bash call, and a false positive costs a real engine launch to work
around. Anything that is not a --harness-eval is not this guard's business at
all - including the grep that finds a defaulted find_child in source.
"""
import json
import subprocess
import sys

RUNNER = sys.argv[1] if len(sys.argv) > 1 else ".claude/hooks/run.sh"

GD = ".claude/scripts/gd.sh --headless -- "

# (label, command, expected)
CASES = [
    # Vacuous: owned defaults to true, and nothing here has an owner.
    ("bare find_child",
     GD + '--harness-eval=\'scene.find_child("Player")\'', "deny"),
    ("recursive only",
     GD + '--harness-eval=\'scene.find_child("Player", true)\'', "deny"),
    ("owned explicitly true",
     GD + '--harness-eval=\'scene.find_child("Player", true, true)\'', "deny"),
    ("find_children defaulted",
     GD + '--harness-eval=\'scene.find_children("*Tree*")\'', "deny"),
    ("find_children stops one short",
     GD + '--harness-eval=\'scene.find_children("*Tree*", "", true)\'', "deny"),
    # The absence check from the run that produced this guard.
    ("absence check, defaulted",
     GD + '--harness-eval=\'scene.find_child("DeadTree*", true) == null\'', "deny"),
    # One good call does not excuse a bad one in the same batch.
    ("bad call inside a batch",
     GD + '--harness-eval=\'scene.find_child("A", true, false).x\' '
        + '--harness-eval=\'scene.find_child("B")\'', "deny"),
    ("comma inside the pattern string",
     GD + '--harness-eval=\'scene.find_child("a,b")\'', "deny"),

    # Correct: owned = false, so the answer means something.
    ("owned false",
     GD + '--harness-eval=\'scene.find_child("Player", true, false)\'', "allow"),
    ("find_children owned false",
     GD + '--harness-eval=\'scene.find_children("*Tree*", "", true, false)\'', "allow"),
    ("nested call, both owned false",
     GD + '--harness-eval=\'scene.find_child("Player", true, false)'
        + '.get_script().get_script_constant_map()["FORWARD_THRUST"]\'', "allow"),
    ("two good calls in one batch",
     GD + '--harness-eval=\'scene.find_child("A", true, false)\' '
        + '--harness-eval=\'scene.find_children("B*", "", true, false).size()\'', "allow"),
    ("comma inside pattern, owned false",
     GD + '--harness-eval=\'scene.find_child("a,b", true, false)\'', "allow"),

    # Not this guard's business.
    ("no find_child at all",
     GD + '--harness-eval=\'scene.chunks_total\'', "allow"),
    ("not a harness-eval command",
     'echo \'scene.find_child("Player")\'', "allow"),
    ("grepping for the bad pattern in source",
     'git diff -- player/player.gd', "allow"),
    ("plain compile run",
     ".claude/scripts/gd.sh --headless --quit-after 120", "allow"),
]

fails = 0
for label, cmd, expected in CASES:
    p = subprocess.run(["bash", RUNNER, "guard_vacuous_eval"],
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
