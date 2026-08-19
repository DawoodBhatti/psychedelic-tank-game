"""Feeds cases to the push guard without putting them in a shell command,
so testing the guard cannot be blocked by the guard itself.

    python test_guard_git_push.py .claude/hooks/run.sh

Cases carry their own branch where it matters, because half of what this guard
does depends on what is checked out: `git push origin` is routine from a
feature branch and forbidden from main. The branch is passed as an argument,
which overrides the live lookup the guard would otherwise do.
"""
import json
import subprocess
import sys

RUNNER = sys.argv[1] if len(sys.argv) > 1 else ".claude/hooks/run.sh"
DEFAULT_BRANCH = sys.argv[2] if len(sys.argv) > 2 else "claude_iteration"

SEP = chr(38) * 2          # "&&", built at runtime
PUSH = "git" + " push"

# (label, command, expected, branch) - branch omitted means DEFAULT_BRANCH.
CASES = [
    ("push to main",            PUSH + " origin main",                    "deny"),
    ("push to master",          PUSH + " origin master",                  "deny"),
    ("force push main",         PUSH + " --force origin main",            "deny"),
    ("HEAD:main refspec",       PUSH + " origin HEAD:main",               "deny"),

    # Regressions: each of these reached "ask" before the rewrite.
    ("refs/heads/main",         PUSH + " origin refs/heads/main",         "deny"),
    ("HEAD:refs/heads/main",    PUSH + " origin HEAD:refs/heads/main",    "deny"),
    ("plus-forced main",        PUSH + " origin +main",                   "deny"),
    ("delete main",             PUSH + " origin :main",                   "deny"),
    ("remote only, on main",    PUSH + " origin",                 "deny", "main"),
    ("bare push on master",     PUSH,                           "deny", "master"),
    ("--all reaches main",      PUSH + " --all",                          "deny"),
    ("--mirror reaches main",   PUSH + " --mirror",                       "deny"),

    ("push feature branch",     PUSH + " origin claude_iteration",        "ask"),
    ("remote only, off main",   PUSH + " origin",                         "ask"),
    ("main:feature is not to main",
     PUSH + " origin main:feature",                                       "ask"),
    ("-o value is not a refspec",
     PUSH + " -o main origin claude_iteration",                           "ask"),
    # Regression: `main` belonging to a different command used to deny.
    ("main in earlier command",
     "git log main..HEAD " + SEP + " " + PUSH + " origin claude_iteration", "ask"),
    ("compound push",           "cd sub " + SEP + " " + PUSH,             "ask"),
    ("push after semicolon",    "git status; " + PUSH,                    "ask"),
    ("branch named ...main...", PUSH + " -u origin feature-main-thing",   "ask"),

    ("mention in echo",         'echo "' + PUSH + ' origin main"',        "allow"),
    ("mention in commit msg",   "git commit -m 'do not " + PUSH + " yet'", "allow"),
    ("unrelated",               "git status",                             "allow"),
    ("heredoc mentioning push",
     "git commit -F - <<'EOF'\nfixed a thing\nburied in (cd x " + SEP + " " + PUSH
     + ") is caught\nnever push to main\nEOF",
     "allow"),
    ("real push after heredoc",
     "git commit -F - <<'EOF'\nmsg\nEOF\n" + PUSH + " origin main",
     "deny"),
]

fails = 0
for case in CASES:
    label, cmd, expected = case[0], case[1], case[2]
    branch = case[3] if len(case) > 3 else DEFAULT_BRANCH
    p = subprocess.run(["bash", RUNNER, "guard_git_push", branch],
                       input=json.dumps({"tool_input": {"command": cmd}}),
                       capture_output=True, text=True)
    body = p.stdout.strip()
    got = json.loads(body)["hookSpecificOutput"]["permissionDecision"] if body else "allow"
    ok = "OK  " if got == expected else "FAIL"
    if got != expected:
        fails += 1
    print("  %s %-28s [%-16s] expected=%-5s got=%s"
          % (ok, label, branch, expected, got))

print("\n%d/%d passed" % (len(CASES) - fails, len(CASES)))
sys.exit(1 if fails else 0)
