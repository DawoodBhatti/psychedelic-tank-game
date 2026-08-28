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
# The pool as it stands (400 candidates, SDFHeightmap at height_scale 0.04):
#   slope degrees  min 0.0    p25 5.246  p50 12.853  p75 17.434  max 42.687
#   openness       min 0.516  p25 0.641  p50 0.703   p75 0.813   max 1.0
#   height         min -10.0  p25 -9.054 p50 -4.343  p75 5.908   max 21.927
#
# Elevation is the exception that needs no re-deriving: it is a RANK, so
# "the top third of this valley" survives the valley changing underneath it.
# That is the whole reason TerrainAnalysis ranks instead of thresholding.

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
## achievable value is `edge_margin / world_extent` - 6 / 96 = 0.0625 today. The
## first version of valley.tres authored 0.06 and 0.03 here, both below that
## floor, so neither bound could ever reject anything: the rules read as though
## they excluded the map edge and did nothing at all. Compute the floor before
## authoring a minimum, and prefer leaving these at their permissive defaults
## when `edge_margin` already does the job.
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
