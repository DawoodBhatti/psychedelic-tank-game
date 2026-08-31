extends Resource
class_name PlacementRule

# "Ridgelines with long sightlines", as data.
#
# The foundation plan's placement table is four English sentences. This resource
# is the machine-readable form of one of them: a band on each of the metrics
# TerrainAnalysis computes. Every field is a RANGE rather than a threshold,
# because two of the four rules ("mid-slopes", "hollows and dead ground") are
# bands and a threshold cannot express them.
#
# THE DEFAULTS ACCEPT EVERYTHING. An unauthored rule scatters uniformly rather
# than placing nothing, so a half-filled .tres is visibly loose instead of
# invisibly empty. `spawn_failures` catches the opposite mistake - a rule so
# tight nothing satisfies it - which is why that number exists.
#
# EVERY THRESHOLD IN AN AUTHORED RULE SHOULD SIT BETWEEN TWO MEASURED NUMBERS.
# TerrainAnalysis.metrics_summary() prints the quantiles of this valley to the
# session log on every load; put a rule's bounds against those, not against
# intuition.
#
# THAT HAS ALREADY BITTEN ONCE. Session C swapped the fBm hills for the Glen Coe
# DEM and every bound in valley.tres went stale in the same instant, because the
# quantiles moved underneath them - the old `min_slope_degrees = 12` was the old
# pool's p25 and became steeper than the new pool's p75, so it rejected 375
# candidates and the prop group placed 6 of 12. Nothing about the rule was
# wrong; it was measured against a valley that no longer existed. Re-read the
# quantiles after ANY change to the ground field.
#
# AND IT WAS RE-READ AGAIN when the world was widened to 384 m at height_scale
# 0.08. That pass is a uniform 2x scale of the same glen, so it left every slope
# angle alone and merely doubled the height axis - which is exactly the shape of
# change that looks like it needs no re-measuring and does. The height row below
# moved by a factor of two; slope and openness drifted, because the analysis
# constants (slope_step 2.0, eye_height 2.0, sight_range 60) are in world units
# and so measure a proportionally smaller feature on a bigger world. The authored
# bounds in valley.tres survived it - 17 of 17 placed, 0 failures - but that was
# measured, not assumed.
#
# The pool as S3 found it (400 candidates, SDFHeightmap at height_scale 0.08 over
# a 384 m footprint) - kept as the BEFORE column for the row under it:
#   slope degrees  min 0.0     p25 5.570   p50 13.181  p75 18.069  max 46.502
#   openness       min 0.469   p25 0.641   p50 0.703   p75 0.828   max 1.0
#   height         min -20.343 p25 -17.839 p50 -7.943  p75 13.383  max 45.207
#
# THE POOL AS IT STANDS, RE-MEASURED 2026-08-31 FOR S4 on the post-S3 field -
# 400 candidates, world 2022 x 2010 (world_extent_x 1011.0, world_extent_z
# 1005.0), height_scale 0.42125, spawn_seed 20260826, read off
# TerrainAnalysis.metrics_summary() through the live Spawner:
#   slope degrees  min 0.0      p25 4.912   p50 13.488  p75 18.229  max 49.094
#   openness       min 0.563    p25 0.641   p50 0.719   p75 0.844   max 1.0
#   height         min -108.335 p25 -93.190 p50 -40.113 p75 74.361  max 241.781
#
# WHAT THE RE-MEASUREMENT ACTUALLY SAID, because "re-derive after a field change"
# is a rule about doing the work, not a prediction of the answer:
#
#   - SLOPE BARELY MOVED (p25 5.570 -> 4.912, p50 13.181 -> 13.488, p75 18.069 ->
#     18.229). It should not have: S3 scaled height_scale with world_size, which
#     holds every gradient in the glen fixed by construction, and the shader's
#     relief constants survived the same pass for the same reason. The 27x growth
#     in area is invisible to an angle.
#   - OPENNESS BARELY MOVED EITHER (p25 0.641 -> 0.641, p50 0.703 -> 0.719, p75
#     0.828 -> 0.844) AND THAT IS THE ROW TO BE CAREFUL WITH, because the number
#     staying put does not mean it still MEASURES the same thing. sight_range is
#     60 world units and the world went from 384 to 2022 across, so openness is
#     now a statement about a 60-unit neighbourhood of a 2022-unit glen - local
#     shelter, not valley-scale exposure. The distribution is not degenerate
#     (min 0.563, and the quartiles are 0.2 apart), so a band on it still selects
#     ground; it selects ground that is locally unobstructed, which is what a
#     landmark wants and is not what the old 0.7-1.0 "long sightlines" meant.
#     Anything wanting exposure at the new scale must raise sight_range first and
#     re-measure this row again.
#   - HEIGHT moved by 5.2656 across the board, exactly height_scale's ratio.
#     Nothing gates on it; it is here as the corroboration that the field really
#     is the post-S3 one.
#
# Elevation is the exception that needs no re-deriving: it is a RANK, so
# "the top third of this valley" survives the valley changing underneath it.
# That is the whole reason TerrainAnalysis ranks instead of thresholding, and it
# is why the widening pass above cost nothing despite doubling the height row.
#
# THE POOL'S PITCH IS THE OTHER NUMBER A RULE IS AUTHORED AGAINST, and it is not
# in the summary because it is a property of the grid rather than of the terrain.
# candidates_per_axis 20 over 2 x (1011 - 6) and 2 x (1005 - 6) gives a nominal
# spacing of 100.5 x 99.9 world units, jittered by +/-0.45 of a step. So the pool
# cannot resolve anything finer than about 100 units, and a SpawnGroup.separation
# well below that is inert for the same reason a min_edge_fraction below the
# margin floor is. The S4 tower group's separation of 110.0 is authored just
# ABOVE that pitch for exactly this reason.
#
# THE ONE RULE AUTHORED AGAINST THE ROW ABOVE is valley.tres's tower group:
#   slope     0 - 20 deg     (20 sits between p75 18.229 and max 49.094)
#   elevation 0.55 - 1.0     (a rank: the upper 45% of the pool, by definition)
#   openness  0.72 - 1.0     (0.72 sits between p50 0.719 and p75 0.844)
#   edge      0 - 1          (left permissive; see min_edge_fraction below)
#
# AND ITS YIELD WAS MEASURED, NOT ASSUMED - which is the half of this that
# spawn_failures alone will not tell you. A rule can place everything it was
# asked for and still be one candidate away from placing nothing, and that
# reads as a pass. Both versions below placed 6 of 6 with 0 failures:
#
#   min_openness 0.78 - the walk examined 392 of the 400 candidates before it
#     filled. Rejections slope 69, elevation 205, openness 111, overlap 1, so
#     SEVEN points in the entire pool satisfied the rule and one of those seven
#     was lost to separation. A green gate with a margin of one.
#   min_openness 0.72 - the walk filled after 110 candidates. Rejections slope
#     17, elevation 54, openness 33, overlap 0. Roughly a fifth of the pool
#     examined for the same six towers, i.e. about 22 satisfying points rather
#     than 7.
#
# The second is what ships. READ THE REJECTION TALLY, NOT JUST THE FAILURE
# COUNT: the number of candidates the walk had to examine is the only thing in
# the log that distinguishes a comfortable rule from a lucky one.
#
# WHAT MADE IT TIGHT IS WORTH KNOWING, because it is a fact about this glen and
# not about these numbers. Of the 126 candidates that passed slope AND elevation
# at the 0.78 bound, only 15 passed openness. High ground here is ridge crests
# with more ground rising within 60 units, so "high" and "locally unobstructed"
# pull against each other rather than together - which is the opposite of what
# the old guardian rule's "ridgelines with long sightlines" assumed, and is a
# direct consequence of sight_range being a 60-unit window on a 2022-unit world.

## Slope band in degrees from horizontal. Guardians want ground flat enough to
## stand on; props want the slopes nothing drives across.
@export var min_slope_degrees: float = 0.0
@export var max_slope_degrees: float = 90.0

## Height band as a rank among the analysed candidates: 0 is the lowest point in
## the valley, 1 the highest. Relative on purpose - see TerrainAnalysis.
@export var min_elevation_percentile: float = 0.0
@export var max_elevation_percentile: float = 1.0

## Sightline band. 1 sees to the horizon in every direction, 0 is boxed in.
@export var min_openness: float = 0.0
@export var max_openness: float = 1.0

## Distance from the world edge as a fraction of the half-extent: 0 at the edge,
## 1 dead centre. `max_edge_fraction` below 1 is how "near a map edge" is said,
## and it is the mechanism session G's gate rule needs.
##
## THIS ONE CANNOT REACH 0, AND A BOUND BELOW THE FLOOR IS INERT. Candidates are
## already held `Spawner.edge_margin` inside the world, so the smallest
## achievable value is `edge_margin / world_extent`.
##
## THE FLOOR MOVES WITH THE WORLD, and it has now moved twice: 6 / 96 = 0.0625
## before the grid was widened, 6 / 192 = 0.03125 after, and since S3
## **6 / 1011 = 0.00594 in x, 6 / 1005 = 0.00597 in z**. A margin held constant
## while the extent grows divides the floor by the same factor, so the bound gets
## quietly weaker every time the world gets bigger - S3 alone made it 5.3x
## weaker. The first version of valley.tres authored 0.06 and 0.03 here, both
## below the 0.0625 floor of the smaller world they were written against, so
## neither bound could ever reject anything: the rules read as though they
## excluded the map edge and did nothing at all. Compute the floor before
## authoring a minimum, and prefer leaving these at their permissive defaults
## when `edge_margin` already does the job - which is what the S4 tower rule
## does, because 6 units of margin on a 2022-unit world is not a placement
## decision worth expressing here.
##
## THE EXTENT IN THAT DIVISION IS THE COLLIDABLE ONE, not the drawn one.
## TerrainAnalysis bounds itself with `world_extent_x()` / `world_extent_z()`,
## which return the HeightMapShape3D's footprint (1011.0 / 1005.0), while the
## clipmap draws to +/-2048 around the player. Widening placement to the drawn
## extent would scatter entities onto ground with no collider under it.
##
## NOTE THE ASYMMETRY WITH THE OTHER THREE METRICS: slope, openness and
## elevation are published as quantiles by TerrainAnalysis.metrics_summary() and
## can be bracketed by measurement. Edge fraction is not, because it is a
## property of the world box rather than of the terrain in it - it is derived in
## closed form from the two numbers above instead.
@export var min_edge_fraction: float = 0.0
@export var max_edge_fraction: float = 1.0


## Empty string when the point satisfies the rule, otherwise the name of the
## FIRST criterion it failed.
##
## The reason this returns a reason rather than a bool: when a group fails to
## place, the only useful question is which bound was too tight, and counting
## rejections by criterion answers it from one load instead of from a bisection
## over the .tres. The Spawner tallies these into its log entry.
func rejected_by(slope: float, percentile: float, open: float, edge: float) -> String:
	if slope < min_slope_degrees or slope > max_slope_degrees:
		return "slope"
	if percentile < min_elevation_percentile or percentile > max_elevation_percentile:
		return "elevation"
	if open < min_openness or open > max_openness:
		return "openness"
	if edge < min_edge_fraction or edge > max_edge_fraction:
		return "edge"
	return ""


## Whether the point satisfies the rule. Delegates to rejected_by() rather than
## repeating the comparisons, so the two can never drift into disagreeing about
## the same point.
func accepts(slope: float, percentile: float, open: float, edge: float) -> bool:
	return rejected_by(slope, percentile, open, edge).is_empty()
