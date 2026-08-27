# diff.sh returns zero lines on a staged change, and says nothing about it

- date: 2026-08-27
- surfaced-by: reviewer
- run: /build session D — entity layer + scatter
- target: agent-file

**Evidence.** Session D's work was committed, then soft-reset so it would not sit in history
until review passed, leaving all 29 paths in the index. On that tree:

    $ .claude/scripts/diff.sh | wc -l
    0
    $ .claude/scripts/diff.sh | head -5          # printed nothing
    $ git --no-pager diff HEAD --stat
     29 files changed, 1428 insertions(+), 23 deletions(-)

`reviewer.md` says "Read the diff with `.claude/scripts/diff.sh`" with no qualification, and
CLAUDE.md § Environment lists it as the sanctioned way to read the working-tree diff. A
Reviewer that ran it on this tree would have received an empty result, exit 0, and no signal
distinguishing "nothing changed" from "everything is staged". I only avoided it because the
orchestrator had checked by hand and warned me in the brief.

The state is not exotic: staging-then-reviewing is the workflow that produced it, so the
pipeline creates the exact condition under which its own diff tool goes silent.

**What it suggests.** Either `diff.sh` covers the index (`git diff HEAD`, or fall back to it
when `git diff` is empty and `git diff --cached` is not), or it prints a one-line warning when
it has nothing to show and `git status --short` is non-empty. A tool whose empty output is
ambiguous between two opposite meanings is worse than no tool, because the reviewer proceeds.
