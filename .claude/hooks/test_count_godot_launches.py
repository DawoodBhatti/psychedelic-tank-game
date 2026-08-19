"""Tests for count_godot_launches.py.

The MUST-NOT-COUNT half is the point. Every one of those is a command this
project actually ran, and every one of them used to be billed as an engine
launch because the log directory is called "Godot".

Run:  python .claude/hooks/test_count_godot_launches.py
"""
import importlib.util, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
# The hook imports hooklib, a sibling. Loading it by file location does not put
# that directory on the path the way running it as a script would.
sys.path.insert(0, HERE)
spec = importlib.util.spec_from_file_location(
    "counter", os.path.join(HERE, "count_godot_launches.py"))
counter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(counter)

GD = ("/c/Users/dabha/Downloads/Godot_v4.7-stable_mono_win64/"
      "Godot_v4.7-stable_mono_win64/Godot_v4.7-stable_mono_win64_console.exe")
LOGS = "/c/Users/dabha/AppData/Roaming/Godot/app_userdata/psychedelic tank game/logs"

CASES = [
    # (expected count, command)
    (1, '"%s" --headless --quit-after 120' % GD),
    (1, '%s --headless -- --harness-check-resources' % GD),
    (1, 'timeout 90 "%s" --headless' % GD),
    (1, 'GD="%s"; "$GD" --headless -- --harness-eval="scene.chunks_total"' % GD),
    (1, 'GD="%s"\n"$GD" --headless --quit-after 300' % GD),
    (1, 'cd marching-cubes-prototype && "%s" --headless' % GD),
    (1, 'godot --headless -- --harness-check-resources'),
    (1, 'GD="%s"; for f in a.gd b.gd; do "$GD" --check-only --script "$f"; done' % GD),
    (1, 'out=$("%s" --headless 2>&1 | grep -c "SCRIPT ERROR")' % GD),
    (2, '"%s" --headless --import && "%s" --headless --quit-after 300' % (GD, GD)),

    # The wrapper IS a launch. It exists to hide the binary from the allow
    # list, which means it hides it from here too - miss these and the cost
    # guard reads zero forever while the engine boots all session.
    (1, 'bash .claude/scripts/gd.sh --headless --quit-after 120'),
    (1, '.claude/scripts/gd.sh --headless -- --harness-check-resources'),
    (1, './.claude/scripts/gd.sh -- --harness-fps=5'),
    (2, 'bash .claude/scripts/gd.sh --headless --quit-after 120; '
        'bash .claude/scripts/gd.sh --headless -- --harness-check-resources'),
    (1, 'bash .claude/scripts/gd.sh -- --harness-shot=0,640,40:0,0,0 '
        '&& python .claude/scripts/check_render.py .claude/images/a.png'),

    # Reading logs, docs and output. None of these boots the engine.
    (0, 'ls -1 "%s"/session_*.log | tail -1' % LOGS),
    (0, 'grep \'"event":"error"\' "$(ls -1t %s/*.log | head -1)"' % LOGS),
    (0, 'cat "$(ls -1t %s/session_*.log | head -1)" | tail -40' % LOGS),
    (0, 'rm -f %s/session_*.log' % LOGS),
    (0, 'echo "Godot Engine v4.7.stable.mono"'),
    (0, 'grep -i godot CLAUDE.md'),
    (0, 'ls /c/Users/dabha/Downloads/Godot_v4.7-stable_mono_win64/'),
    (0, 'git log --oneline | grep -i godot'),
    (0, 'git status --short'),
    (0, 'python .claude/scripts/usage_report.py'),

    # Reading or searching the wrapper is not running it.
    (0, 'cat .claude/scripts/gd.sh'),
    (0, 'grep -n harness .claude/scripts/gd.sh'),
    (0, 'ls -l .claude/scripts/gd.sh'),
    (0, 'bash .claude/scripts/newest-log.sh'),
]


def run():
    failures = []
    for expected, command in CASES:
        got = counter.count_launches(command)
        if got != expected:
            failures.append((expected, got, command))
    for exp, got, cmd in failures:
        print("FAIL expected=%d got=%d  %s" % (exp, got, cmd.replace("\n", "\\n")[:100]))
    print("\n%d/%d passed" % (len(CASES) - len(failures), len(CASES)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(run())
