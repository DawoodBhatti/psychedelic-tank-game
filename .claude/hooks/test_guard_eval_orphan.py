"""Feeds cases to the orphan-eval guard without putting them in a shell
command, so testing the guard cannot be blocked by the guard itself.

    python test_guard_eval_orphan.py .claude/hooks/run.sh

Same priority as the vacuous-eval tests: the cases that must stay ALLOWED are
the interesting ones. This guard sits on every Bash call, and a false positive
costs a real engine launch to work around.
"""
import json
import subprocess
import sys

RUNNER = sys.argv[1] if len(sys.argv) > 1 else ".claude/hooks/run.sh"

GD = ".claude/scripts/gd.sh --headless -- "

# (label, command, expected)
CASES = [
    # The measured case: reads the right number, leaks at exit.
    ("bare instantiate",
     GD + "--harness-eval='scene.tank.shell_scene.instantiate().hit_mask'", "deny"),
    ("preload then instantiate",
     GD + "--harness-eval='preload(\"res://shell.tscn\").instantiate().hit_mask'", "deny"),
    # One parented call does not excuse an orphan in the same batch.
    ("orphan inside a batch",
     GD + "--harness-eval='scene.add_child(scene.tank.shell_scene.instantiate())' "
        + "--harness-eval='scene.tank.shell_scene.instantiate().hit_mask'", "deny"),
    ("add_child on a DIFFERENT node, orphan alongside",
     GD + "--harness-eval='scene.add_child(scene.spare) if scene.tank.shell_scene"
        + ".instantiate() else null'", "deny"),

    # Parented in the same expression: the tree owns it.
    ("wrapped in add_child",
     GD + "--harness-eval='scene.add_child(scene.tank.shell_scene.instantiate())'", "allow"),
    ("wrapped, with a paren inside a string",
     GD + "--harness-eval='scene.add_child(preload(\"res://a(1).tscn\").instantiate())'",
     "allow"),

    # The sanctioned path: the game builds and parents it.
    ("game construction path",
     GD + "--harness-eval='scene.tank.fire()'", "allow"),
    ("reading off the tree afterwards",
     GD + "--harness-eval='scene.get_child(scene.get_child_count() - 1).hit_mask'", "allow"),

    # .new() is deliberately out of scope - most are RefCounted.
    ("RefCounted .new()",
     GD + "--harness-eval='RandomNumberGenerator.new().randi()'", "allow"),

    # Not this guard's business.
    ("plain eval",
     GD + "--harness-eval='scene.chunks_total'", "allow"),
    ("not a harness-eval command",
     "echo 'scene.tank.shell_scene.instantiate()'", "allow"),
    ("grepping for instantiate in source",
     "git diff -- tank/tank.gd", "allow"),
    ("plain compile run",
     ".claude/scripts/gd.sh --headless --quit-after 120", "allow"),
]

fails = 0
for label, cmd, expected in CASES:
    p = subprocess.run(["bash", RUNNER, "guard_eval_orphan"],
                       input=json.dumps({"tool_input": {"command": cmd}}),
                       capture_output=True, text=True)
    body = p.stdout.strip()
    got = json.loads(body)["hookSpecificOutput"]["permissionDecision"] if body else "allow"
    ok = "OK  " if got == expected else "FAIL"
    if got != expected:
        fails += 1
    print("  %s %-40s expected=%-5s got=%s" % (ok, label, expected, got))

print("\n%d/%d passed" % (len(CASES) - fails, len(CASES)))
sys.exit(1 if fails else 0)
