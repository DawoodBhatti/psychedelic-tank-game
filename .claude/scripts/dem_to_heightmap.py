#!/usr/bin/env python3
"""Convert an Arc ASCII Grid DEM into a 16-bit greyscale PNG heightmap.

WHY THIS EXISTS RATHER THAN gdal_translate. The foundation plan names
`gdal_translate -ot UInt16 -scale -of PNG` for this step. That needs GDAL, which
needs QGIS or OSGeo4W - a ~1 GB install to transform one 100 KB file. Arc ASCII
Grid is plain text, so the whole conversion is stdlib `zlib` + `struct`. The
download stays a manual human step either way; this is a converter, not a
fetcher, and the distinction is the one CLAUDE.md draws in its out-of-scope list.

THE TRAP THIS EXISTS TO FIX, AND IT IS SILENT. An .asc in EPSG:4326 has cells
that are square in DEGREES, not in metres. A degree of longitude shrinks with
latitude - at 56.67 N it is ~61 km against ~111 km for a degree of latitude - so
a square patch of GROUND arrives as a rectangle of PIXELS. The Glen Coe crop is
119x65 for a ~2.02 x 2.00 km footprint: a 1.83:1 pixel aspect over 1.005:1 of
actual ground.

Sampled with equal x/z scaling that terrain is stretched 83% along one axis. It
does not look broken. It looks like a slightly odd glen, which is exactly the
kind of wrong this project keeps paying for. So this script RESAMPLES TO A
SQUARE GRID before writing, and everything downstream may assume isotropic
pixels. Fixing it here means one place knows about the projection instead of
`SDFHeightmap`, the shader ramp, and whatever samples it next.

ROW ORDER. Arc ASCII Grid writes NORTH first; PNG row 0 is the top. They agree,
so no flip happens here and image row 0 is the northern edge. Anything binding
this to a world axis should state which way +Z runs rather than assume.

The sidecar .json written next to the PNG carries the elevation range and the
ground footprint, so `height_scale` is derived from measured numbers rather than
guessed. See the foundation plan: real Highland relief is several hundred metres
and this world has ~17 m of it, so that scale is a small fraction of real.
"""

import argparse
import json
import struct
import sys
import zlib
from pathlib import Path

NODATA_DEFAULT = -32768.0


def read_asc(path):
    """Parse an Arc ASCII Grid. Returns (header dict, list of rows of float)."""
    header = {}
    rows = []
    expected_keys = ("ncols", "nrows", "xllcorner", "yllcorner", "cellsize")

    with open(path, "r", encoding="ascii", errors="replace") as handle:
        for line in handle:
            parts = line.split()
            if not parts:
                continue
            key = parts[0].lower()
            # The header is done the moment a line leads with a number.
            if key in ("ncols", "nrows", "xllcorner", "yllcorner", "yllcenter",
                       "xllcenter", "cellsize", "nodata_value"):
                header[key] = float(parts[1])
                continue
            rows.append([float(v) for v in parts])

    for key in expected_keys:
        if key not in header:
            raise SystemExit(f"ASC header is missing '{key}' - is {path} really an Arc ASCII Grid?")

    ncols, nrows = int(header["ncols"]), int(header["nrows"])

    # Rows may be wrapped across lines; flatten and re-split on ncols so a
    # differently-wrapped file from another source still parses.
    flat = [v for row in rows for v in row]
    if len(flat) != ncols * nrows:
        raise SystemExit(
            f"Expected {ncols * nrows} samples ({ncols}x{nrows}), read {len(flat)}."
        )
    grid = [flat[r * ncols:(r + 1) * ncols] for r in range(nrows)]
    return header, grid


def fill_nodata(grid, nodata):
    """Replace NODATA with the mean of valid neighbours, iterating until clean.

    Voids are rare in NASADEM over land but not impossible, and a single -32768
    left in place would drag the whole normalisation range with it - the entire
    glen would quantise into a handful of levels and read as flat.
    """
    nrows, ncols = len(grid), len(grid[0])
    holes = [(r, c) for r in range(nrows) for c in range(ncols) if grid[r][c] == nodata]
    if not holes:
        return 0

    filled_total = 0
    for _ in range(64):
        if not holes:
            break
        remaining = []
        for r, c in holes:
            acc, n = 0.0, 0
            for dr in (-1, 0, 1):
                for dc in (-1, 0, 1):
                    rr, cc = r + dr, c + dc
                    if 0 <= rr < nrows and 0 <= cc < ncols and grid[rr][cc] != nodata:
                        acc += grid[rr][cc]
                        n += 1
            if n:
                grid[r][c] = acc / n
                filled_total += 1
            else:
                remaining.append((r, c))
        if len(remaining) == len(holes):
            break  # nothing is reachable; give up rather than spin
        holes = remaining

    if holes:
        raise SystemExit(f"{len(holes)} NODATA cells have no valid neighbour - crop is unusable.")
    return filled_total


def bilinear_resample(grid, out_w, out_h):
    """Resample to out_w x out_h. Plain bilinear - the source is already smooth."""
    in_h, in_w = len(grid), len(grid[0])
    if in_w == out_w and in_h == out_h:
        return [row[:] for row in grid]

    out = []
    # Map output pixel CENTRES onto input pixel centres, so the edges line up
    # and the result is not shifted by half a cell.
    for y in range(out_h):
        sy = (y + 0.5) * in_h / out_h - 0.5
        y0 = max(0, min(in_h - 1, int(sy // 1)))
        y1 = min(in_h - 1, y0 + 1)
        fy = max(0.0, min(1.0, sy - y0))
        row = []
        for x in range(out_w):
            sx = (x + 0.5) * in_w / out_w - 0.5
            x0 = max(0, min(in_w - 1, int(sx // 1)))
            x1 = min(in_w - 1, x0 + 1)
            fx = max(0.0, min(1.0, sx - x0))
            top = grid[y0][x0] * (1.0 - fx) + grid[y0][x1] * fx
            bot = grid[y1][x0] * (1.0 - fx) + grid[y1][x1] * fx
            row.append(top * (1.0 - fy) + bot * fy)
        out.append(row)
    return out


def write_png16(path, grid):
    """Write a 16-bit greyscale PNG. Stdlib only: zlib for deflate and CRC."""
    height, width = len(grid), len(grid[0])

    raw = bytearray()
    for row in grid:
        raw.append(0)  # filter type 0 (None) - the data is noisy enough that
                       # per-scanline prediction buys little and costs clarity
        for value in row:
            raw += struct.pack(">H", value)

    def chunk(tag, payload):
        return (struct.pack(">I", len(payload)) + tag + payload
                + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF))

    ihdr = struct.pack(">IIBBBBB", width, height, 16, 0, 0, 0, 0)
    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", ihdr)
           + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
           + chunk(b"IEND", b""))
    Path(path).write_bytes(png)
    return len(png)


def verify_png16(path, expected):
    """Decode the file we just wrote and prove it matches `expected`.

    This encoder is ~20 lines of hand-rolled chunk framing, and the failure mode
    of getting it wrong is not an exception - it is a file that Godot silently
    declines to import, discovered later at the cost of an engine launch. So the
    converter proves its own output rather than asserting it.
    """
    data = Path(path).read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit("VERIFY FAILED: PNG signature is wrong.")

    pos, chunks = 8, {}
    while pos < len(data):
        length = struct.unpack(">I", data[pos:pos + 4])[0]
        tag = data[pos + 4:pos + 8]
        payload = data[pos + 8:pos + 8 + length]
        stored = struct.unpack(">I", data[pos + 8 + length:pos + 12 + length])[0]
        if zlib.crc32(tag + payload) & 0xFFFFFFFF != stored:
            raise SystemExit(f"VERIFY FAILED: CRC mismatch on chunk {tag!r}.")
        chunks.setdefault(tag, b"")
        chunks[tag] += payload
        pos += 12 + length

    for required in (b"IHDR", b"IDAT", b"IEND"):
        if required not in chunks:
            raise SystemExit(f"VERIFY FAILED: no {required!r} chunk.")

    w, h, depth, colour, comp, filt, inter = struct.unpack(">IIBBBBB", chunks[b"IHDR"])
    if (depth, colour) != (16, 0):
        raise SystemExit(f"VERIFY FAILED: expected 16-bit greyscale, got depth={depth} colour={colour}.")
    if (w, h) != (len(expected[0]), len(expected)):
        raise SystemExit(f"VERIFY FAILED: {w}x{h} on disk, {len(expected[0])}x{len(expected)} expected.")
    if (comp, filt, inter) != (0, 0, 0):
        raise SystemExit("VERIFY FAILED: unexpected compression/filter/interlace.")

    raw = zlib.decompress(chunks[b"IDAT"])
    stride = 1 + w * 2
    if len(raw) != stride * h:
        raise SystemExit(f"VERIFY FAILED: {len(raw)} raw bytes, expected {stride * h}.")

    mismatches = 0
    for y in range(h):
        base = y * stride
        if raw[base] != 0:
            raise SystemExit(f"VERIFY FAILED: row {y} has filter byte {raw[base]}, expected 0.")
        row = struct.unpack(f">{w}H", raw[base + 1:base + stride])
        for x in range(w):
            if row[x] != expected[y][x]:
                mismatches += 1
    if mismatches:
        raise SystemExit(f"VERIFY FAILED: {mismatches} sample(s) differ after round-trip.")
    return w, h, depth


def self_test():
    """Prove verify_png16 can FAIL, not merely that it passes.

    A checker that never rejects anything is indistinguishable from no checker,
    and the green line it prints is worse than silence because it is believed.
    So: write a known-good file and confirm it passes, then corrupt it four
    different ways and confirm each one is caught.
    """
    import tempfile

    grid = [[(y * 37 + x * 911) % 65536 for x in range(16)] for y in range(9)]
    failures = []

    with tempfile.TemporaryDirectory() as tmp:
        good = Path(tmp) / "good.png"
        write_png16(good, grid)

        try:
            verify_png16(good, grid)
            print("SELFTEST: clean file verifies                      PASS")
        except SystemExit as exc:
            failures.append(f"clean file was rejected: {exc}")

        cases = {
            "flipped pixel byte": lambda b: (b.__setitem__(len(b) - 20, b[len(b) - 20] ^ 0xFF), b)[1],
            "corrupted IHDR CRC": lambda b: (b.__setitem__(29, b[29] ^ 0xFF), b)[1],
            "truncated file": lambda b: b[:len(b) // 2],
            "wrong expected size": None,  # handled below - feeds a mismatched grid
        }

        for name, mutate in cases.items():
            broken = Path(tmp) / "broken.png"
            if mutate is None:
                write_png16(broken, grid)
                expected = [row[:8] for row in grid]  # half the width
            else:
                broken.write_bytes(bytes(mutate(bytearray(good.read_bytes()))))
                expected = grid
            try:
                verify_png16(broken, expected)
                failures.append(f"{name} was NOT caught")
                print(f"SELFTEST: {name:<40} NOT CAUGHT")
            except SystemExit:
                print(f"SELFTEST: {name:<40} caught")
            except Exception:
                # A malformed file may raise before reaching an explicit check.
                # Still a rejection, which is what matters.
                print(f"SELFTEST: {name:<40} caught (raised)")

    if failures:
        for f in failures:
            print(f"SELFTEST FAILURE: {f}")
        return 1
    print("SELFTEST: all checks behaved correctly")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("input", nargs="?", help="the .asc file")
    ap.add_argument("output", nargs="?", help="the .png to write")
    ap.add_argument("--size", type=int, default=0,
                    help="square output edge; default is the longer input axis")
    ap.add_argument("--self-test", action="store_true",
                    help="prove the round-trip verifier rejects corrupt files, then exit")
    args = ap.parse_args()

    if args.self_test:
        return self_test()
    if not args.input or not args.output:
        ap.error("input and output are required unless --self-test is given")

    header, grid = read_asc(args.input)
    ncols, nrows = int(header["ncols"]), int(header["nrows"])
    cellsize = header["cellsize"]
    nodata = header.get("nodata_value", NODATA_DEFAULT)
    lat = header.get("yllcorner", header.get("yllcenter", 0.0))

    voids = fill_nodata(grid, nodata)

    flat = [v for row in grid for v in row]
    lo, hi = min(flat), max(flat)
    mean = sum(flat) / len(flat)
    if hi - lo < 1e-9:
        raise SystemExit("Elevation range is zero - the crop is flat, which it should not be.")

    # Ground footprint. A degree of latitude is ~111.32 km everywhere; a degree
    # of longitude is that times cos(latitude). This is the arithmetic the pixel
    # aspect hides.
    import math
    mid_lat = lat + (nrows * cellsize) / 2.0
    m_per_deg_lat = 111_320.0
    m_per_deg_lon = 111_320.0 * math.cos(math.radians(mid_lat))
    width_m = ncols * cellsize * m_per_deg_lon
    height_m = nrows * cellsize * m_per_deg_lat

    side = args.size or max(ncols, nrows)
    square = bilinear_resample(grid, side, side)

    span = hi - lo
    quantised = [[int(round((v - lo) / span * 65535.0)) for v in row] for row in square]
    png_bytes = write_png16(args.output, quantised)
    vw, vh, vdepth = verify_png16(args.output, quantised)

    meta = {
        "source": str(args.input),
        "source_grid": {"ncols": ncols, "nrows": nrows, "cellsize_deg": cellsize},
        "output_grid": {"width": side, "height": side},
        "ground_footprint_m": {"width": round(width_m, 1), "height": round(height_m, 1)},
        "pixel_aspect_corrected": round((ncols / nrows) / (width_m / height_m), 4),
        "elevation_m": {"min": lo, "max": hi, "mean": round(mean, 2), "range": round(span, 2)},
        "nodata_cells_filled": voids,
        "encoding": "16-bit greyscale PNG, row 0 = NORTH, "
                    "elevation_m = min + (sample / 65535) * range",
        "height_scale_hint": "This world has ~17 m of relief (SDFHills amplitude 22). "
                             f"Real range here is {round(span, 1)} m, so a 1:1 mapping is "
                             f"~{round(span / 17.0, 1)}x too tall. Tune against "
                             "Terrain.surface_height_range(), do not guess.",
    }
    meta_path = Path(args.output).with_suffix(".json")
    meta_path.write_text(json.dumps(meta, indent=2), encoding="utf-8")

    print(f"DEM: {ncols}x{nrows} cells @ {cellsize:.9f} deg  (NODATA filled: {voids})")
    print(f"DEM: ground footprint {width_m:.0f} x {height_m:.0f} m  "
          f"(pixel aspect {ncols / nrows:.3f}:1 over ground aspect {width_m / height_m:.3f}:1)")
    print(f"DEM: elevation min {lo:.1f} m  max {hi:.1f} m  mean {mean:.1f} m  range {span:.1f} m")
    print(f"DEM: resampled to {side}x{side} square, wrote {png_bytes} bytes -> {args.output}")
    print(f"DEM: VERIFY PASS - round-tripped {vw}x{vh} @ {vdepth}-bit greyscale, "
          f"all {vw * vh} samples identical, every chunk CRC valid")
    print(f"DEM: metadata -> {meta_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
