"""Answer "does it render?" about a screenshot, WITHOUT reading it into context.

WHY THIS EXISTS. CLAUDE.md test 6 asks a reviewer whether a --harness-shot
rendered: present, not black, not inside-out, not invisible, not culled. The
only way to answer that by looking is Read on the png, and guard_image_read.py
denies exactly that - an image read costs ~3.3k tokens and is re-sent on every
later turn for the life of the session. The guard's escape hatch
(CLAUDE_ALLOW_IMAGE_READ=1) is an environment variable on the Claude process,
which a subagent cannot set for itself. So the documented test had no supported
mechanism, and a reviewer either skipped it or improvised.

Measuring pixels is the better answer anyway. "Does it render" is a mechanical
question with a right answer, and this project's whole discipline is to measure
the number rather than trust a description of it. This reads the file, prints
one line, and costs nothing that lasts.

    python .claude/scripts/check_render.py .claude/images/layout.png

Prints `RENDER: PASS|FAIL {json}` and exits 0 / 1, matching the HARNESS:
convention so a caller can branch on the exit code instead of parsing text.

REGION MODE answers the OTHER measurable question - not "did the frame render"
but "is the thing I just changed actually in it".

    python .claude/scripts/check_render.py shot.png --region 0.3,0.3,0.7,0.85 \
        --expect warm_bright_frac '>' 0.001

This exists because the question kept getting answered by writing a throwaway
script into the scratchpad - one that reached into this file's private _read_png
to borrow the decoder, hardcoded one scene's colour thresholds, and was invented
again the next time. That code was untracked, unreviewable and unrepeatable, and
the reviewer approving it could not see what it measured. The recurring shape
belongs in the tracked tool.

Region coordinates are FRACTIONS of width and height (0..1), so a camera pose
change does not silently move the box. `--expect KEY OP VALUE` may be repeated,
OP is one of > >= < <= , and KEY is any numeric field in the output, including
`hue_frac.orange`. Prints `REGION: PASS|FAIL {json}` and sets the exit code.

In region mode the whole-frame render verdict is NOT applied: a tight crop can
legitimately be flat, and failing it for that would be measuring the crop rather
than the render. Ask "does it render" of the frame and "is it there" of the
region, in two calls.

SWEEPS AND TABLES answer "WHERE along here does it change?" - which is a
different question from either of the above, and the one that kept getting
answered in shell.

    python .claude/scripts/check_render.py shot.png \
        --region 0.0,0.42,1.0,0.48 --columns 24 \
        --format tsv --fields luma_mean,distinct_colours

`--region` is now REPEATABLE and takes an optional `:label`, `--columns N`
slices each region into N vertical strips left to right (labelled `c00`..),
`--fields` narrows the output to the keys named, and `--format tsv` prints one
row per region instead of one JSON line per region. Every `--expect` is applied
to EVERY region, so one threshold can be swept across a band.

WHY THESE EXIST, since they are otherwise just conveniences. Without them the
recurring shape was a shell `for` loop calling this script once per strip,
computing the fractions with `python -c` and parsing the JSON with a second
`python -c`. Measured on one review: seven such commands, of which six needed no
permission that was not already granted - they broke `Bash(python
.claude/scripts/*)` by decorating themselves with `cd`, a variable assignment,
and `python -c`, which is deliberately NOT allowlisted and so prompts the user
every time. A 24-strip sweep also invoked this script 48 times and dumped 48
lines of interleaved output into context; `--columns 24 --format tsv` is one
invocation and one table. Cheaper to run, cheaper to read, and it prompts nobody.

The single-region JSON form is unchanged, byte for byte. Calls already written
into CLAUDE.md, reviewer.md and past reviews keep working.

CONTROL MODE measures the same boxes on a SECOND image and reports the
difference, so a comparison against a control is one command instead of two
tables joined by hand.

    python .claude/scripts/check_render.py subject.png --control control.png \
        --region 0.0,0.490,1.0,0.497 --columns 576 --format tsv \
        --fields delta.luma_mean,delta.hue_frac.cyan

Every numeric field gains a `delta.<key>` twin, computed as SUBJECT MINUS
CONTROL, and `--expect` reads them like any other key (`--expect
delta.luma_mean '<' -2`). Both images must be the same size; a mismatch is a
hard failure rather than a rescale, because the whole value of a control is
that it is the same pixels.

WHY, since deltas are arithmetic anyone could do. Two horizon sweeps drew
OPPOSITE wrong conclusions from this tool, one reporting a hole that was fogged
rock and one reporting closure over a real gap, because each compared a single
channel against a number carried in from somewhere else. A column matches the
control or it does not, and that is only answerable with both channels of both
images in front of you at once. Post-mortem in pipeline-notes.md, fold 5.

CALIBRATE THE THRESHOLD AGAINST THE PAIR, DO NOT GUESS IT. Measured here: an
UNLIT campfire shot scored warm_bright_frac 0.00187 against a lit-fire guess of
0.001, and would have "proved" a fire that was not burning. Sunlit grass, a low
sun and pale stone all read warm and bright. The number is only meaningful as a
difference: measure the same region on the before shot, then on the after shot,
and put the threshold between them. An absolute threshold picked from intuition
is a coin flip with a JSON blob attached.

ON THE THRESHOLDS. They are deliberately LOOSE. They were calibrated against
one known-good frame and no known-bad one, so anything tight would be a guess
dressed as a measurement, and a check that cries wolf on a legitimate art change
is a check that gets ignored. These catch gross failure - a black frame, a flat
fill, a missing-material magenta wash, geometry that never drew - and nothing
subtler. Taste is not measured here. Composition, colour and style are the
user's call, judged from the image itself.

Stdlib only: PIL is not a dependency of this project and should not become one.
"""
import json
import os
import struct
import sys
import zlib

# --- thresholds (see ON THE THRESHOLDS above) ---------------------------------

# A frame darker than this almost everywhere never drew. A legitimately dark
# night scene still carries a sky gradient and specular highlights.
NEAR_BLACK_LUMA = 16
MAX_NEAR_BLACK_FRAC = 0.98

# Distinct colours after quantising to 5 bits per channel. A flat fill, a
# cleared buffer or a single untextured plane lands in the low tens.
MIN_DISTINCT_COLOURS = 64

# Godot's fallback for a broken material is not magenta, but shader compile
# failures and several importers do produce it, and no art in this project is
# saturated magenta. Any meaningful amount is a defect.
MAX_MAGENTA_FRAC = 0.02

# --- colour families (region mode) --------------------------------------------
#
# Named by HUE rather than by subject. "warm_bright" is a measurable property of
# a pixel; "fire" is an interpretation of one, and the moment a threshold is
# named after the thing it is hoped to find, it stops being a measurement. Fire,
# a lit window and a low sun all read as warm_bright, and the caller says which
# one it expected by choosing the region.

# Below this value a pixel is "dark" regardless of hue - hue is meaningless in
# near-blackness, where sensor-style noise swings it wildly.
FAMILY_DARK_VALUE = 40
# Below this saturation it is "grey" - stone, concrete, overcast, bare metal.
FAMILY_GREY_SAT = 0.15
# Value at which a warm pixel reads as EMITTING rather than merely being brown.
WARM_BRIGHT_VALUE = 200
# Warm = red through yellow, the two ends of the hue circle around 0.
WARM_HUE_MAX = 70
WARM_HUE_MIN = 345

HUE_BUCKETS = (
    (15, "red"), (45, "orange"), (70, "yellow"), (170, "green"),
    (200, "cyan"), (260, "blue"), (290, "purple"), (345, "magenta"),
    (360, "red"),
)

# Every family `_family()` can return. `hue_frac` is seeded from this so a
# bucket with no pixels is reported as an explicit 0.0 rather than being
# absent. The distinction is not cosmetic: `--expect hue_frac.cyan '<' 0.01`
# used to FAIL with "no numeric field" on the very frames where the answer was
# a clean zero, which reads exactly like a threshold breach. Absent now means
# only "you asked for a key that does not exist", i.e. a typo.
FAMILIES = ("dark", "grey") + tuple(name for _, name in HUE_BUCKETS)


def _read_png(path):
    """Decode a non-interlaced 8-bit PNG to (width, height, channels, bytes)."""
    with open(path, "rb") as handle:
        data = handle.read()

    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG")

    pos = 8
    idat = bytearray()
    width = height = depth = colour_type = interlace = None

    while pos < len(data):
        (length,) = struct.unpack(">I", data[pos:pos + 4])
        kind = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        pos += 12 + length  # length + type + body + crc

        if kind == b"IHDR":
            width, height, depth, colour_type, _, _, interlace = struct.unpack(
                ">IIBBBBB", body)
        elif kind == b"IDAT":
            idat += body
        elif kind == b"IEND":
            break

    if depth != 8:
        raise ValueError("expected 8-bit channels, got %s" % depth)
    if interlace:
        raise ValueError("interlaced PNG not supported")

    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[colour_type]
    raw = zlib.decompress(bytes(idat))

    stride = width * channels
    out = bytearray(height * stride)
    prev = bytearray(stride)
    at = 0

    for row in range(height):
        filter_type = raw[at]
        at += 1
        line = bytearray(raw[at:at + stride])
        at += stride

        # PNG per-scanline filters; `channels` is the byte distance to the
        # pixel on the left.
        if filter_type == 1:
            for i in range(channels, stride):
                line[i] = (line[i] + line[i - channels]) & 0xFF
        elif filter_type == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif filter_type == 3:
            for i in range(stride):
                left = line[i - channels] if i >= channels else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif filter_type == 4:
            for i in range(stride):
                left = line[i - channels] if i >= channels else 0
                upleft = prev[i - channels] if i >= channels else 0
                up = prev[i]
                p = left + up - upleft
                pa, pb, pc = abs(p - left), abs(p - up), abs(p - upleft)
                if pa <= pb and pa <= pc:
                    pred = left
                elif pb <= pc:
                    pred = up
                else:
                    pred = upleft
                line[i] = (line[i] + pred) & 0xFF
        elif filter_type != 0:
            raise ValueError("bad PNG filter %s" % filter_type)

        out[row * stride:(row + 1) * stride] = line
        prev = line

    return width, height, channels, out


def _hue(r, g, b, mx, mn):
    """Hue in degrees, 0-360. Undefined for greys, which return 0."""
    span = mx - mn
    if span == 0:
        return 0.0
    if mx == r:
        h = ((g - b) / span) % 6
    elif mx == g:
        h = (b - r) / span + 2
    else:
        h = (r - g) / span + 4
    return h * 60.0


def _family(r, g, b):
    """Classify one pixel as (colour family, is it warm AND bright)."""
    mx = max(r, g, b)
    if mx < FAMILY_DARK_VALUE:
        return "dark", False
    if (mx - min(r, g, b)) / mx < FAMILY_GREY_SAT:
        return "grey", False

    h = _hue(r, g, b, mx, min(r, g, b))
    family = "red"
    for edge, name in HUE_BUCKETS:
        if h < edge:
            family = name
            break
    warm = (h < WARM_HUE_MAX or h >= WARM_HUE_MIN) and mx >= WARM_BRIGHT_VALUE
    return family, warm


def _measure(width, height, channels, pixels, box=None):
    """Walk the image once, on a grid, collecting every statistic we need.

    `box` is (x0, y0, x1, y1) in pixels, half-open, defaulting to the whole
    frame. The sampling stride is computed from the BOX, not the image, so a
    small region is still sampled densely rather than reduced to four pixels.
    """
    x0, y0, x1, y1 = box if box else (0, 0, width, height)

    # A stride keeps this O(200k) samples regardless of resolution, so a 4K
    # shot costs the same as a 720p one. Prime-ish steps avoid aligning with
    # any regular pattern in the image.
    step_x = max(1, (x1 - x0) // 400)
    step_y = max(1, (y1 - y0) // 400)

    total = 0
    near_black = 0
    magenta = 0
    warm_bright = 0
    luma_sum = 0
    luma_min = 255
    luma_max = 0
    colours = set()
    families = {}
    # Mean luminance per horizontal band, to see a sky-over-ground structure.
    bands = 12
    band_sum = [0] * bands
    band_count = [0] * bands

    for y in range(y0, y1, step_y):
        band = min(bands - 1, (y - y0) * bands // max(1, y1 - y0))
        row = y * width * channels
        for x in range(x0, x1, step_x):
            at = row + x * channels
            if channels >= 3:
                r, g, b = pixels[at], pixels[at + 1], pixels[at + 2]
            else:
                r = g = b = pixels[at]

            luma = (r * 299 + g * 587 + b * 114) // 1000
            total += 1
            luma_sum += luma
            luma_min = min(luma_min, luma)
            luma_max = max(luma_max, luma)
            if luma <= NEAR_BLACK_LUMA:
                near_black += 1
            # Saturated magenta: strong red and blue, weak green.
            if r > 180 and b > 180 and g < 90:
                magenta += 1
            colours.add(((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3))
            family, warm = _family(r, g, b)
            families[family] = families.get(family, 0) + 1
            if warm:
                warm_bright += 1
            band_sum[band] += luma
            band_count[band] += 1

    if not total:
        raise ValueError("region contains no pixels")

    band_means = [
        round(band_sum[i] / band_count[i], 1) if band_count[i] else 0.0
        for i in range(bands)
    ]

    return {
        "width": width,
        "height": height,
        "sampled_pixels": total,
        "near_black_frac": round(near_black / total, 4),
        "magenta_frac": round(magenta / total, 4),
        "warm_bright_frac": round(warm_bright / total, 5),
        "distinct_colours": len(colours),
        "luma_min": luma_min,
        "luma_max": luma_max,
        "luma_mean": round(luma_sum / total, 1),
        "band_means": band_means,
        "hue_frac": {k: round(families.get(k, 0) / total, 4)
                     for k in sorted(FAMILIES)},
    }


def _verdict(m):
    """Return the list of failures. Empty means it rendered."""
    failures = []

    if m["near_black_frac"] > MAX_NEAR_BLACK_FRAC:
        failures.append(
            "black frame: %.1f%% of sampled pixels are near-black"
            % (m["near_black_frac"] * 100))

    if m["distinct_colours"] < MIN_DISTINCT_COLOURS:
        failures.append(
            "flat fill: only %d distinct colours, expected >= %d - geometry "
            "likely never drew" % (m["distinct_colours"], MIN_DISTINCT_COLOURS))

    if m["magenta_frac"] > MAX_MAGENTA_FRAC:
        failures.append(
            "missing material or failed shader: %.1f%% magenta"
            % (m["magenta_frac"] * 100))

    if m["luma_max"] - m["luma_min"] < 8:
        failures.append(
            "no contrast: luminance spans %d-%d - a cleared buffer, not a scene"
            % (m["luma_min"], m["luma_max"]))

    return failures


OPS = {
    ">": lambda a, b: a > b,
    ">=": lambda a, b: a >= b,
    "<": lambda a, b: a < b,
    "<=": lambda a, b: a <= b,
}

USAGE = ("usage: check_render.py <image.png> [--control control.png] "
         "[--region x0,y0,x1,y1[:label]]... "
         "[--columns N] [--fields KEY,KEY,...] [--format json|tsv] "
         "[--expect KEY OP VALUE]...")

# Fields a delta would describe but not measure: the frame's own dimensions,
# and the sample count, which follows the box rather than the picture.
NO_DELTA = ("width", "height", "sampled_pixels")

# Printed by --format tsv when the caller did not name its own fields. Short on
# purpose: the point of a table is to be read at a glance down dozens of rows,
# and hue_frac alone would add six columns nobody asked for.
DEFAULT_TSV_FIELDS = ["luma_mean", "luma_min", "luma_max", "distinct_colours"]


def _parse_region(spec):
    """Parse `x0,y0,x1,y1` with an optional `:label` suffix."""
    body, _, name = spec.partition(":")
    parts = body.split(",")
    if len(parts) != 4:
        raise ValueError("--region needs x0,y0,x1,y1 as fractions 0..1")
    try:
        box = [float(p) for p in parts]
    except ValueError:
        raise ValueError("--region needs four numbers, got %r" % body)
    if not all(0.0 <= v <= 1.0 for v in box):
        raise ValueError("--region values are fractions, so 0..1")
    if box[0] >= box[2] or box[1] >= box[3]:
        raise ValueError("--region needs x0<x1 and y0<y1")
    return box, (name or None)


def _split_columns(box, count, name):
    """Slice one box into `count` vertical strips, left to right.

    The last strip takes the parent's exact right edge rather than an
    accumulated one. Float drift would otherwise leave a sliver of the band
    unmeasured, and that is invisible in the output while being wrong in
    exactly the way that matters - a sweep is used to find WHERE something
    starts, so a missing column at the end is a missing answer.
    """
    x0, y0, x1, y1 = box
    span = (x1 - x0) / count
    strips = []
    for i in range(count):
        left = x0 + span * i
        right = x1 if i == count - 1 else x0 + span * (i + 1)
        strips.append(([left, y0, right, y1],
                       "%s.c%02d" % (name, i) if name else "c%02d" % i))
    return strips


def _delta(subject, control):
    """Subject minus control, for every numeric leaf, keeping the shape.

    Lists (band_means) are skipped rather than zipped: a band-by-band
    difference reads like a measurement but the bands are cut from each box
    independently, so the pairing is only meaningful when the boxes match
    exactly - which is the case this cannot check.
    """
    out = {}
    for key, value in subject.items():
        if key in NO_DELTA or key not in control:
            continue
        other = control[key]
        if isinstance(value, dict) and isinstance(other, dict):
            out[key] = _delta(value, other)
        elif isinstance(value, bool) or isinstance(other, bool):
            continue
        elif isinstance(value, (int, float)) and isinstance(other, (int, float)):
            out[key] = round(value - other, 5)
    return out


def _parse_args(argv):
    """Return (path, control, [(box, label), ...], expects, fields, fmt, columns)."""
    if len(argv) < 2:
        raise ValueError(USAGE)

    path, regions, expects = argv[1], [], []
    fields, fmt, columns, control = None, "json", None, None
    i = 2
    while i < len(argv):
        if argv[i] == "--control":
            if i + 1 >= len(argv):
                raise ValueError("--control needs a path to a second image")
            control = argv[i + 1]
            i += 2
        elif argv[i] == "--region":
            if i + 1 >= len(argv):
                raise ValueError("--region needs x0,y0,x1,y1 as fractions 0..1")
            regions.append(_parse_region(argv[i + 1]))
            i += 2
        elif argv[i] == "--columns":
            if i + 1 >= len(argv):
                raise ValueError("--columns needs a count")
            try:
                columns = int(argv[i + 1])
            except ValueError:
                raise ValueError("--columns needs a whole number, got %r"
                                 % argv[i + 1])
            if columns < 1:
                raise ValueError("--columns needs a count of 1 or more")
            i += 2
        elif argv[i] == "--fields":
            if i + 1 >= len(argv):
                raise ValueError("--fields needs a comma-separated list")
            fields = [f for f in argv[i + 1].split(",") if f]
            if not fields:
                raise ValueError("--fields needs at least one key")
            i += 2
        elif argv[i] == "--format":
            if i + 1 >= len(argv) or argv[i + 1] not in ("json", "tsv"):
                raise ValueError("--format must be json or tsv")
            fmt = argv[i + 1]
            i += 2
        elif argv[i] == "--expect":
            if i + 3 >= len(argv):
                raise ValueError("--expect needs KEY OP VALUE")
            key, op, value = argv[i + 1], argv[i + 2], argv[i + 3]
            if op not in OPS:
                raise ValueError("--expect OP must be one of %s"
                                 % " ".join(sorted(OPS)))
            expects.append((key, op, float(value)))
            i += 4
        else:
            raise ValueError("unknown argument %r. %s" % (argv[i], USAGE))
    return path, control, regions, expects, fields, fmt, columns


def _lookup(measured, key):
    """Fetch a numeric field, supporting one level of dotting (hue_frac.red)."""
    node = measured
    for part in key.split("."):
        if not isinstance(node, dict) or part not in node:
            return None
        node = node[part]
    return node if isinstance(node, (int, float)) else None


def _to_box(frac, width, height):
    """Fractions to a pixel box, clamped so a thin strip is never empty."""
    return (int(frac[0] * width), int(frac[1] * height),
            max(int(frac[0] * width) + 1, int(frac[2] * width)),
            max(int(frac[1] * height) + 1, int(frac[3] * height)))


def _print_json(rows, fields, tag, path):
    """One `TAG: PASS|FAIL {json}` line per region - the original shape.

    For a single unlabelled region with no --fields this is byte-identical to
    what the tool printed before sweeps existed, which is what keeps the calls
    already written into CLAUDE.md and reviewer.md working unchanged.
    """
    for name, failures, measured, box in rows:
        if measured is None:
            out = {}
        elif fields:
            out = {k: _lookup(measured, k) for k in fields}
        else:
            out = dict(measured)
        if name:
            out["label"] = name
        out["path"] = path
        if box:
            out["region_px"] = list(box)
        out["failures"] = failures
        print("%s: %s %s" % (tag, "PASS" if not failures else "FAIL",
                             json.dumps(out)))


def _print_tsv(rows, fields, tag, path):
    """A table: one row per region, one column per field.

    This exists to kill `| python -c "import sys,json; ..."`. Pulling two
    numbers out of the JSON was by far the most repeated shell idiom against
    this tool, it needs `python -c` - deliberately not allowlisted, so it
    prompts - and a 24-strip sweep paid that prompt 24 times over.
    """
    keys = fields or DEFAULT_TSV_FIELDS
    print("# " + "\t".join(["region", "status"] + keys))
    for name, failures, measured, _box in rows:
        cells = []
        for key in keys:
            value = None if measured is None else _lookup(measured, key)
            cells.append("-" if value is None else "%g" % value)
        print("\t".join([name or "frame",
                         "PASS" if not failures else "FAIL"] + cells))

    bad = sum(1 for row in rows if row[1])
    print("%s: %s %s" % (tag, "PASS" if not bad else "FAIL", json.dumps(
        {"path": path, "regions": len(rows), "failed": bad})))


def _load(path):
    """Decode a png, or raise ValueError carrying the message to print."""
    if not os.path.isfile(path):
        raise ValueError("no such file: %s" % path)
    try:
        return _read_png(path)
    except Exception as exc:  # noqa: BLE001 - any decode failure is a failure
        raise ValueError("could not decode %s: %s" % (path, exc))


def main(argv):
    try:
        path, control, regions, expects, fields, fmt, columns = _parse_args(argv)
    except ValueError as exc:
        print("RENDER: FAIL " + json.dumps({"error": str(exc)}))
        return 1

    # --columns slices whatever was asked for; with no --region that is the
    # whole frame. Either way the result IS a set of regions, so the
    # whole-frame render verdict below stops applying - a single strip of a
    # real frame is legitimately flat, exactly as a tight crop is.
    if columns:
        source = regions or [([0.0, 0.0, 1.0, 1.0], None)]
        regions = []
        for box, name in source:
            regions.extend(_split_columns(box, columns, name))

    tag = "REGION" if regions else "RENDER"

    try:
        width, height, channels, pixels = _load(path)
        ctl = _load(control) if control else None
    except ValueError as exc:
        print("%s: FAIL %s" % (tag, json.dumps(
            {"error": str(exc), "path": path})))
        return 1

    # Same pixels or nothing. Rescaling to compare would move every boundary in
    # the frame by a sub-pixel amount, which is precisely the size of the
    # features a sweep is looking for.
    if ctl and (ctl[0], ctl[1]) != (width, height):
        print("%s: FAIL %s" % (tag, json.dumps({
            "error": "control is %dx%d, subject is %dx%d - a control must be "
                     "the same size, shot at the same resolution"
                     % (ctl[0], ctl[1], width, height),
            "path": path, "control": control})))
        return 1

    rows, failed = [], False

    for frac, name in (regions or [(None, None)]):
        box = _to_box(frac, width, height) if frac else None
        try:
            measured = _measure(width, height, channels, pixels, box)
            if ctl:
                measured["delta"] = _delta(
                    measured, _measure(ctl[0], ctl[1], ctl[2], ctl[3], box))
                measured["control"] = control
        except ValueError as exc:
            # One bad strip must not abort a 24-column sweep: report it in
            # place and carry on, or every row after it is lost as well.
            rows.append((name, [str(exc)], None, box))
            failed = True
            continue

        # Whole frame: the render verdict. Region: only what the caller asked
        # for - see the note in the module docstring on why the two are not
        # combined.
        failures = [] if frac else _verdict(measured)

        for key, op, want in expects:
            got = _lookup(measured, key)
            if got is None:
                failures.append("no numeric field %r to test" % key)
            elif not OPS[op](got, want):
                failures.append("expected %s %s %g, measured %g"
                                % (key, op, want, got))

        rows.append((name, failures, measured, box))
        failed = failed or bool(failures)

    if fmt == "tsv":
        _print_tsv(rows, fields, tag, path)
    else:
        _print_json(rows, fields, tag, path)

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
