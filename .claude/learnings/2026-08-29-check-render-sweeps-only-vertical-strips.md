# check_render's only sweep axis is the wrong one for a horizontally-banded feature

- date: 2026-08-29
- surfaced-by: reviewer
- run: /begin S1 — feel pass: recoil, aim coupling, contour lines
- target: test

**Evidence.** `check_render.py --columns N` slices a region into VERTICAL strips
(`_split_columns` divides x only); there is no `--rows`. Elevation contours are iso-Y lines and
render as roughly horizontal bands, so the built-in sweep runs parallel to nothing and
perpendicular to nothing useful. The Doer swept 30 columns over `x 0.35–0.65, y 0.55–0.85` and
reported `delta.luma_mean` "oscillating ±5–8 with a ~4-strip period" as its banding evidence —
but each of those strips averages 498 px of height, i.e. many contour lines, so the periodicity
it measured is terrain shape varying in x and would appear on a control with no contours at all.
Measuring the same frame with explicit horizontal strips (40 `--region` args, ~4 px tall) showed
the actual line structure the column sweep could not: troughs at `delta.luma_mean −0.7 / +0.4`
and peaks at `+28.8`, period ≈29 px, with `delta.hue_frac.grey` moving in phase (+0.24 → +0.68).
Both sweeps "showed banding"; only one of them measured it.

**What it suggests.** Either a `--rows N` twin of `--columns` in `check_render.py`, or a line in
its docstring saying that a sweep resolves nothing along the axis it does not cut, so the strip
must run ACROSS the feature — the existing "a sweep resolves nothing finer than one column" note
in CLAUDE.md warns about strip width but not about strip orientation, which is the failure that
actually occurred here. Writing horizontal strips by hand costs a 40-argument command line, which
is its own argument for the flag.
