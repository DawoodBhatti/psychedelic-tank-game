"""Measure the in-force instruction surface and diff it against the last fold.

The in-force surface is what every agent is actually governed by: `CLAUDE.md`,
every agent file, every command file, and `settings.json`. It is re-read on
every turn of every session, so it is the one part of the pipeline whose growth
compounds, and `/consolidate` reports it as the only signal that consolidation
is still working.

    python .claude/scripts/check_surface.py                        # measure and diff
    python .claude/scripts/check_surface.py --record "fold 4"      # ...and bank the total

The label is a positional argument to `--record` rather than an environment
variable, because `SURFACE_LABEL=... python ...` leads with a bare assignment:
the decoration guard rejects it, and it would not match the
`Bash(python .claude/scripts/*)` allow rule even if it did.

Why this is a script and not a `wc -c` in the command file. Fold 3 wrote its
own surface figure into `pipeline-notes.md` from memory *before* measuring:
it published "53794 -> 53810, +16 ... the prose files came out at -216 net",
and the measured answer was **54595, +801**, with `CLAUDE.md` alone up 588.
Wrong in magnitude, wrong in sign on its load-bearing half, and wrong in the
flattering direction - it described the outcome the command says to aim for.
Nothing caught it; the run happened to measure afterwards.

That number is the only evidence the mechanism is working, and a consolidator
estimating it will estimate it low, having just spent a session believing its
own deletions were substantial. So the number is produced by a command rather
than by an agent's arithmetic - the same argument that put `check_render.py`
behind test 6 instead of a description of the image.

The file set is GLOBBED, never listed. A new agent or command file joins the
surface the day it is written, with nobody remembering to add it here.
"""
import glob
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
HISTORY = os.path.join(ROOT, ".claude", "surface-history.json")

# Mirrors `wc -c CLAUDE.md .claude/agents/*.md .claude/commands/*.md
# .claude/settings.json`. Deliberately excludes model-sources.json, which is
# data the modeller reads rather than instructions governing anyone, and which
# grows as `candidates` fills.
PATTERNS = (
    "CLAUDE.md",
    os.path.join(".claude", "agents", "*.md"),
    os.path.join(".claude", "commands", "*.md"),
    os.path.join(".claude", "settings.json"),
)


def measure():
    """Return (total, {relpath: size}) over the globbed in-force surface."""
    sizes = {}
    for pattern in PATTERNS:
        for path in sorted(glob.glob(os.path.join(ROOT, pattern))):
            rel = os.path.relpath(path, ROOT).replace(os.sep, "/")
            sizes[rel] = os.path.getsize(path)
    return sum(sizes.values()), sizes


def load_history():
    if not os.path.exists(HISTORY):
        return []
    with open(HISTORY, "r", encoding="utf-8") as handle:
        return json.load(handle).get("readings", [])


def main(argv):
    args = argv[1:]
    record, label = False, "unlabelled fold"
    while args:
        arg = args.pop(0)
        if arg == "--record":
            record = True
            # An optional label may follow, but only if it is not itself a flag.
            if args and not args[0].startswith("--"):
                label = args.pop(0)
        else:
            print('unknown argument %r. Usage: check_surface.py '
                  '[--record ["label"]]' % arg)
            return 2

    total, sizes = measure()
    readings = load_history()
    previous = readings[-1] if readings else None

    if previous:
        old = previous["total"]
        delta = total - old
        print("SURFACE: %d -> %d, %+d  (since %s, %s)"
              % (old, total, delta, previous["date"], previous["label"]))
    else:
        old, delta = None, None
        print("SURFACE: %d  (no previous reading banked)" % total)

    print("")
    was = (previous or {}).get("files", {})
    for rel in sorted(sizes):
        before = was.get(rel)
        if before is None:
            print("  %-28s %6d  (new)" % (rel, sizes[rel]))
        else:
            print("  %-28s %6d  %+d" % (rel, sizes[rel], sizes[rel] - before))
    for rel in sorted(set(was) - set(sizes)):
        print("  %-28s %6s  (deleted, was %d)" % (rel, "-", was[rel]))

    if record:
        import datetime
        date = datetime.date.today().isoformat()
        readings.append({"date": date, "label": label,
                         "total": total, "files": sizes})
        with open(HISTORY, "w", encoding="utf-8") as handle:
            json.dump({"readings": readings}, handle, indent=2)
            handle.write("\n")
        print("\nbanked as reading %d in %s"
              % (len(readings), os.path.relpath(HISTORY, ROOT)))
    elif previous:
        print("\nnot banked. Re-run with --record once the fold is finished.")

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
