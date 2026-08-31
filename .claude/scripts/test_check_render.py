"""Tests for check_render.py, following the test_*.py convention in .claude/hooks/.

The point of these is not that the happy path passes - it is that the check
FAILS on the images it is supposed to reject. A render check that cannot fail is
worse than no check, because it reads like evidence.

Each case synthesises a PNG in memory rather than committing fixture files, so
the failure modes are described in code and nothing has to be kept in sync.

    python .claude/scripts/test_check_render.py
"""
import os
import struct
import subprocess
import sys
import tempfile
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "check_render.py")


def write_png(path, width, height, pixel_fn):
    """Write an 8-bit RGB PNG, filter 0, using pixel_fn(x, y) -> (r, g, b)."""
    raw = bytearray()
    for y in range(height):
        raw.append(0)  # filter type 0 (None) for every scanline
        for x in range(width):
            r, g, b = pixel_fn(x, y)
            raw += bytes((r & 0xFF, g & 0xFF, b & 0xFF))

    def chunk(kind, body):
        return (struct.pack(">I", len(body)) + kind + body
                + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF))

    with open(path, "wb") as handle:
        handle.write(b"\x89PNG\r\n\x1a\n")
        handle.write(chunk(b"IHDR", struct.pack(
            ">IIBBBBB", width, height, 8, 2, 0, 0, 0)))
        handle.write(chunk(b"IDAT", zlib.compress(bytes(raw))))
        handle.write(chunk(b"IEND", b""))


def run(path, *args):
    """Run the checker, returning (exit_code, stdout)."""
    proc = subprocess.run(
        [sys.executable, SCRIPT, path] + [str(a) for a in args],
        capture_output=True, text=True)
    return proc.returncode, proc.stdout.strip()


# --- the images -------------------------------------------------------------

def scene_like(x, y):
    """A plausible render: sky gradient on top, textured ground below.

    The three channels vary INDEPENDENTLY. An earlier version of this fixture
    moved them in lockstep and produced only 22 distinct colours, which tripped
    the flat-fill check - a fair verdict on the fixture rather than on the
    checker, since no real render varies its channels together. The real
    reference shot measures 465 distinct colours against a threshold of 64.
    """
    if y < 160:
        return (80 + y // 3, 130 + y // 2, 200 - y // 5)  # sky gradient
    # Coprime moduli, so the three channels do not repeat in step: cheap
    # stand-in for texture detail.
    return (55 + (x * 7 + y * 13) % 37,
            100 + (x * 11 + y * 5) % 53,
            40 + (x * 3 + y * 17) % 29)  # ground


def lit_scene(x, y):
    """`scene_like` with a bright warm blob in the middle - a lit fire.

    The unlit version of the same shot is `scene_like` itself, which is the
    whole point: the two differ only in the thing being tested, so a region
    check that passes on both is measuring nothing.
    """
    if 130 < x < 190 and 130 < y < 190:
        return (245 + (x % 10), 140 + (y % 40), 40 + (x % 20))
    return scene_like(x, y)


# The horizon pair, built to the measured shape of the real failure. Sky and
# fogged rock at the SAME luminance, differing only in hue: a far peak hazed
# toward the sky colour reads 219 flat, and so does the sky behind it. Sweeping
# luma alone cannot tell them apart in either direction, which is how one run
# reported a hole that was rock and another reported closure over a hole.
SKY = (190, 224, 238)   # luma 215, cyan family (hue ~197)
FOG = (215, 215, 215)   # luma 215 too, but grey - no cyan at all


def horizon_control(x, y):
    """Open sky across the whole band: the geometry-free control frame."""
    if 144 <= y < 176:
        return (SKY[0] + (x % 3), SKY[1] + (y % 3), SKY[2] - (x % 2))
    return scene_like(x, y)


def horizon_subject(x, y):
    """The same frame with a fogged peak filling x 160-192 of the band."""
    if 144 <= y < 176 and 160 <= x < 192:
        return (FOG[0] + (x % 3),) * 3
    return horizon_control(x, y)


CASES = [
    ("renders normally", scene_like, 0),
    ("black frame", lambda x, y: (0, 0, 0), 1),
    ("flat fill", lambda x, y: (34, 78, 120), 1),
    ("magenta / missing material", lambda x, y: (255, 0, 255), 1),
    # Near-black but not pure: the guard must not be fooled by a couple of
    # stray lit pixels in an otherwise dead frame.
    ("almost entirely black", lambda x, y: (200, 200, 200)
        if (x == 0 and y == 0) else (2, 2, 3), 1),
]


def main():
    failures = []

    with tempfile.TemporaryDirectory() as tmp:
        for name, fn, want_code in CASES:
            path = os.path.join(tmp, name.replace(" ", "_").replace("/", "") + ".png")
            write_png(path, 320, 320, fn)
            code, out = run(path)
            ok = code == want_code
            print("%-32s exit=%d want=%d  %s" % (name, code, want_code,
                                                 "ok" if ok else "MISMATCH"))
            if not ok:
                failures.append("%s: exit %d, wanted %d\n    %s"
                                % (name, code, want_code, out))

        # --- region mode ---------------------------------------------------
        # The pair that matters: the SAME expectation against a lit and an
        # unlit frame. Only one of them may pass.
        lit = os.path.join(tmp, "lit.png")
        unlit = os.path.join(tmp, "unlit.png")
        write_png(lit, 320, 320, lit_scene)
        write_png(unlit, 320, 320, scene_like)

        region = ("--region", "0.3,0.3,0.7,0.7")
        warm = ("--expect", "warm_bright_frac", ">", "0.01")

        region_cases = [
            ("region finds the fire", (lit,) + region + warm, 0),
            ("region misses absent fire", (unlit,) + region + warm, 1),
            # A region outside the blob must not find it either - otherwise the
            # box is decorative and the check would pass wherever it pointed.
            ("region elsewhere is empty",
             (lit, "--region", "0.0,0.0,0.2,0.2") + warm, 1),
            # Named-family lookup, and the dotted form.
            ("hue_frac lookup works",
             (lit,) + region + ("--expect", "hue_frac.orange", ">", "0.01"), 0),
            # No expectations = report only. A flat crop is not a failure in
            # region mode, which is the difference from the whole-frame verdict.
            ("region without expects only reports",
             (lit, "--region", "0.45,0.45,0.5,0.5"), 0),
            # Bad input fails cleanly rather than raising.
            ("region needs four numbers", (lit, "--region", "0.1,0.2"), 1),
            ("region rejects pixels as coords",
             (lit, "--region", "40,40,200,200"), 1),
            ("expect rejects unknown op",
             (lit,) + region + ("--expect", "warm_bright_frac", "~", "0.01"), 1),
            ("expect rejects unknown field",
             (lit,) + region + ("--expect", "no_such_key", ">", "0"), 1),
            # A hue bucket with no pixels is a MEASURED ZERO, not a missing
            # field. The top-left crop of `lit` is pure sky gradient, so it
            # holds no orange at all - and asking whether orange is absent
            # there must PASS. This used to fail with "no numeric field",
            # which is byte-identical to a real threshold breach, so proving
            # the absence of something cost two extra verification launches
            # every time. See .claude/pipeline-notes.md, fold 4.
            ("absent hue bucket reads as zero",
             (lit, "--region", "0.0,0.0,0.2,0.2",
              "--expect", "hue_frac.orange", "<", "0.001"), 0),
            # ...and the genuine typo must STILL fail, or the fix above has
            # merely moved the ambiguity rather than removed it.
            ("misspelled hue bucket still fails",
             (lit, "--region", "0.0,0.0,0.2,0.2",
              "--expect", "hue_frac.taupe", "<", "0.001"), 1),
            ("unknown argument is refused", (lit, "--wat"), 1),
        ]

        for name, args, want_code in region_cases:
            code, out = run(*args)
            ok = code == want_code
            print("%-32s exit=%d want=%d  %s" % (name, code, want_code,
                                                 "ok" if ok else "MISMATCH"))
            if not ok:
                failures.append("%s: exit %d, wanted %d\n    %s"
                                % (name, code, want_code, out))
            if "Traceback" in out:
                failures.append("%s raised instead of reporting" % name)

        # --- sweeps and tables ----------------------------------------------
        sweep_cases = [
            ("columns sweep runs",
             (lit, "--region", "0.0,0.4,1.0,0.6", "--columns", "4"), 0),
            ("columns without region sweeps frame", (lit, "--columns", "3"), 0),
            ("tsv table prints",
             (lit, "--columns", "4", "--format", "tsv"), 0),
            ("fields narrow the output",
             (lit, "--columns", "2", "--format", "tsv",
              "--fields", "luma_mean"), 0),
            # An --expect applies to EVERY strip, so sweeping across an edge
            # fails overall. That is precisely what makes a sweep locate
            # something rather than just describe it.
            ("expect across a sweep fails where absent",
             (lit, "--region", "0.0,0.4,1.0,0.6", "--columns", "4",
              "--expect", "warm_bright_frac", ">", "0.01"), 1),
            ("labelled region is accepted",
             (lit, "--region", "0.3,0.3,0.7,0.7:fire"), 0),
            # A --fields key that does not exist is a display gap, not a
            # failure; --expect is the thing that judges.
            ("unknown field prints as a gap",
             (lit, "--columns", "2", "--format", "tsv",
              "--fields", "no_such_key"), 0),
            ("rows sweep runs",
             (lit, "--region", "0.0,0.4,1.0,0.6", "--rows", "4"), 0),
            ("rows without region sweeps frame", (lit, "--rows", "3"), 0),
            ("rows and columns together are refused",
             (lit, "--rows", "2", "--columns", "2"), 1),
            ("columns rejects zero", (lit, "--columns", "0"), 1),
            ("columns rejects non-numeric", (lit, "--columns", "many"), 1),
            ("rows rejects zero", (lit, "--rows", "0"), 1),
            ("rows rejects non-numeric", (lit, "--rows", "many"), 1),
            ("format rejects unknown", (lit, "--format", "xml"), 1),
            ("fields rejects empty", (lit, "--fields", ""), 1),
        ]

        for name, args, want_code in sweep_cases:
            code, out = run(*args)
            ok = code == want_code
            print("%-32s exit=%d want=%d  %s" % (name, code, want_code,
                                                 "ok" if ok else "MISMATCH"))
            if not ok:
                failures.append("%s: exit %d, wanted %d\n    %s"
                                % (name, code, want_code, out))
            if "Traceback" in out:
                failures.append("%s raised instead of reporting" % name)

        # The discriminating measurement, not just an exit code. The fire
        # spans x 130-190 of 320, so over four strips the middle two cover it
        # and the outer two do not. A sweep whose strips all agreed would be
        # measuring nothing, which is the failure this guards.
        code, out = run(lit, "--region", "0.0,0.4,1.0,0.6", "--columns", "4",
                        "--format", "tsv", "--fields", "warm_bright_frac")
        body = [line for line in out.splitlines()
                if line and not line.startswith(("#", "REGION:"))]
        if len(body) != 4:
            failures.append("sweep produced %d rows, wanted 4" % len(body))
            print("%-32s %s" % ("sweep locates the fire", "MISMATCH"))
        else:
            warm = [float(line.split("\t")[2]) for line in body]
            located = (warm[1] > 0.01 and warm[2] > 0.01
                       and warm[0] <= 0.01 and warm[3] <= 0.01)
            print("%-32s %s" % ("sweep locates the fire",
                                "ok" if located else "MISMATCH"))
            if not located:
                failures.append("sweep did not locate the fire: %s" % warm)

        # The same fire, found on the OTHER axis. It spans y 130-190 of 320, so
        # over four horizontal strips the middle two cover it and the outer two
        # do not - the mirror of the case above, and the one a --columns sweep
        # structurally cannot answer.
        code, out = run(lit, "--region", "0.4,0.0,0.6,1.0", "--rows", "4",
                        "--format", "tsv", "--fields", "warm_bright_frac")
        body = [line for line in out.splitlines()
                if line and not line.startswith(("#", "REGION:"))]
        if len(body) != 4:
            failures.append("row sweep produced %d rows, wanted 4" % len(body))
            print("%-32s %s" % ("row sweep locates the fire", "MISMATCH"))
        else:
            warm = [float(line.split("\t")[2]) for line in body]
            located = (warm[1] > 0.01 and warm[2] > 0.01
                       and warm[0] <= 0.01 and warm[3] <= 0.01)
            print("%-32s %s" % ("row sweep locates the fire",
                                "ok" if located else "MISMATCH"))
            if not located:
                failures.append("row sweep did not locate the fire: %s" % warm)

        # --- control mode ----------------------------------------------------
        subject = os.path.join(tmp, "horizon_subject.png")
        control = os.path.join(tmp, "horizon_control.png")
        write_png(subject, 320, 320, horizon_subject)
        write_png(control, 320, 320, horizon_control)

        band = ("--region", "0.0,0.45,1.0,0.55")
        rock = ("--region", "0.5,0.45,0.6,0.55")   # the fogged peak
        open_sky = ("--region", "0.1,0.45,0.2,0.55")

        control_cases = [
            ("control mode runs", (subject, "--control", control) + band, 0),
            # THE PAIR THAT MATTERS. On the fogged peak, a luma-only test for
            # "something is there" finds nothing - the rock is the same
            # brightness as the sky it stands against...
            ("luma delta cannot see fogged rock",
             (subject, "--control", control) + rock
             + ("--expect", "delta.luma_mean", "<", "-2"), 1),
            # ...while the hue delta sees it immediately. Same box, same two
            # images, opposite answers: this is why the guidance is "match the
            # control on BOTH", not "clear a luma threshold".
            ("hue delta sees fogged rock",
             (subject, "--control", control) + rock
             + ("--expect", "delta.hue_frac.cyan", "<", "-0.5"), 0),
            # And on genuinely open sky, both channels match the control. A
            # test that also "found" rock here would be measuring nothing.
            ("open sky matches control on luma",
             (subject, "--control", control) + open_sky
             + ("--expect", "delta.luma_mean", ">", "-1",
                "--expect", "delta.luma_mean", "<", "1"), 0),
            ("open sky matches control on hue",
             (subject, "--control", control) + open_sky
             + ("--expect", "delta.hue_frac.cyan", ">", "-0.01"), 0),
            # A control of a different size is refused rather than rescaled:
            # the point of a control is that it is the same pixels.
            ("control of another size is refused",
             (subject, "--control", os.path.join(tmp, "truncated_ok.png")), 1),
            ("missing control fails cleanly",
             (subject, "--control", os.path.join(tmp, "nope.png")), 1),
            ("control needs a path", (subject, "--control"), 1),
        ]

        write_png(os.path.join(tmp, "truncated_ok.png"), 160, 160, scene_like)

        for name, args, want_code in control_cases:
            code, out = run(*args)
            ok = code == want_code
            print("%-32s exit=%d want=%d  %s" % (name, code, want_code,
                                                 "ok" if ok else "MISMATCH"))
            if not ok:
                failures.append("%s: exit %d, wanted %d\n    %s"
                                % (name, code, want_code, out))
            if "Traceback" in out:
                failures.append("%s raised instead of reporting" % name)

        # The discriminating measurement behind those exit codes, printed so a
        # reader can see the fixture really does put rock and sky at the same
        # luminance rather than merely asserting it.
        code, out = run(subject, "--control", control, "--format", "tsv",
                        "--fields", "delta.luma_mean,delta.hue_frac.cyan",
                        "--region", "0.5,0.45,0.6,0.55:rock",
                        "--region", "0.1,0.45,0.2,0.55:sky")
        rows = dict()
        for line in out.splitlines():
            if line and not line.startswith(("#", "REGION:")):
                cells = line.split("\t")
                rows[cells[0]] = (float(cells[2]), float(cells[3]))
        indistinguishable = (
            len(rows) == 2
            and abs(rows["rock"][0]) < 1.0            # rock luma == sky luma
            and abs(rows["sky"][0]) < 1.0
            and rows["rock"][1] < -0.5                # but its cyan is gone
            and abs(rows["sky"][1]) < 0.01)
        print("%-32s %s" % ("fogged rock hides in luma only",
                            "ok" if indistinguishable else "MISMATCH"))
        if not indistinguishable:
            failures.append("horizon fixture does not reproduce the failure: %s"
                            % rows)

        # Backward compatibility is the whole constraint on this change: the
        # single-region form is written into CLAUDE.md and reviewer.md, and
        # into every review already done. It must print what it always did.
        code, out = run(lit, "--region", "0.3,0.3,0.7,0.7")
        unchanged = (out.startswith("REGION: PASS {")
                     and '"label"' not in out
                     and '"delta"' not in out
                     and '"region_px"' in out
                     and len(out.splitlines()) == 1)
        print("%-32s %s" % ("single region output unchanged",
                            "ok" if unchanged else "MISMATCH"))
        if not unchanged:
            failures.append("single-region output changed:\n    %s" % out)

        # A truncated file must fail cleanly rather than raise.
        bad = os.path.join(tmp, "truncated.png")
        write_png(bad, 32, 32, scene_like)
        with open(bad, "r+b") as handle:
            handle.truncate(40)
        code, out = run(bad)
        print("%-32s exit=%d want=1  %s" % ("truncated file", code,
                                            "ok" if code == 1 else "MISMATCH"))
        if code != 1:
            failures.append("truncated file: exit %d, wanted 1" % code)
        if "Traceback" in out:
            failures.append("truncated file raised instead of reporting")

    print()
    if failures:
        print("FAILED (%d)" % len(failures))
        for f in failures:
            print("  " + f)
        return 1

    print("All %d cases passed."
          % (len(CASES) + len(region_cases) + len(sweep_cases)
             + len(control_cases) + 4))
    return 0


if __name__ == "__main__":
    sys.exit(main())
