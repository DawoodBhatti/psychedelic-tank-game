# A control screenshot is only a control for the commit it was shot at, and mtime cannot tell you which

- date: 2026-08-30
- surfaced-by: reviewer
- run: /begin S1b - camera height and the contour flicker
- target: claude.md

**Evidence.** S1b's roadmap gate named `.claude/images/s1-contours-before.png` as the control to
diff against. It is S1's PRE-contour frame, and S1's commit (7c0a5a8) changed two things at that
pose, not one: the contours, and the grid dial-back
(`git show 7c0a5a8 -- terrain/materials/neon_terrain.tres` gives `emission_strength 2.4 -> 1.6`,
`line_width 0.045 -> 0.035`). Against it a pure contour FADE measures as *adding* +14.9 luma,
which a fade cannot do. The Doer detected this and argued from mtime - the image is 20:38, the
S1 commit 21:08 - but that argument is unsound: `/begin` commits after the session ends, so
EVERY image a session shoots predates its own commit. `s1-contours-after.png` (20:46) and
`s1-review-after.png` (20:52) predate 21:08 as well. The sound test needed no launch and was a
tool the project already has: `check_render.py s1-review-after.png --control s1-contours-after.png`
measures delta 0 on every field (same rendered state, so `s1-review-after.png` IS post-S1), while
`s1-contours-after.png --control s1-contours-before.png` measures +14.9 luma / +0.391 grey (so
`s1-contours-before.png` is pre-contour).

**What it suggests.** CLAUDE.md test 6 says "shoot the same pose before and after", which is
right within one session but silent on the case that bit here - a later session's gate naming an
earlier session's image. Two lines would close it: a control shot in a previous session is valid
only against that session's commit, and every commit between it and now is folded into the
delta; and identify which state an image holds by measuring it against another image with
`--control`, never by its mtime against a commit, because the commit always lands last.
