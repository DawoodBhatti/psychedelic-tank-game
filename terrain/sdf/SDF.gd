extends Resource
class_name SDF

# How much this field can over-report distance: the largest factor by which
# |grad sample()| can exceed 1. Anything that sphere-traces this SDF (the
# pathfinder's segment checks, and the planned empty-space skipping pass) must
# divide a sampled distance by this before treating it as a safe step, or it
# can jump clean over thin geometry. 1.0 = a true distance field.
#
# Exact primitives and union/intersect/subtract/onion preserve 1.0; noise
# displacement and scaling of the result do not. See SDFOps for which is which.
var lipschitz: float = 1.0


func sample(p: Vector3, chunk_offset: Vector3 = Vector3.ZERO) -> float:
	push_error("SDF.sample() not implemented")
	return 0.0

func on_generate() -> void:
	pass


# ---------------------------------------------------------
# Height-field interface — optional, and NOT every SDF answers it
# ---------------------------------------------------------
# Implemented only by fields whose sample() has the shape
# `p.y - surface_height(x, z)`: SDFHills, a future SDFHeightmap, and any
# composite stacked out of them. A sphere has no single surface height and
# says so.
#
# It sits on the BASE CLASS rather than being duck-typed at the call site
# because TerrainField.ground is declared as `SDF` — it may be one field or a
# whole composite — and both callers reach it through that reference:
# Terrain.surface_height() (which decides where the tank spawns) and the neon
# material's hue ramp. A `has_method()` check at those sites would move a
# configuration error to a place that cannot report it usefully.
#
# BOTH DEFAULTS FAIL LOUDLY RATHER THAN RETURNING A PLAUSIBLE NUMBER. A silent
# 0.0 from surface_height() spawns the tank at y = spawn_clearance in mid-air
# over the middle of the map, which is a wrong number wearing a working
# number's clothes — the exact failure class this project exists to catch.
# ErrorCapture turns the push_error into a test-3 failure.

## Height of the surface at a world x/z, in world units, ignoring anything
## carved out of it afterwards. What to stand something on.
func surface_height(_x: float, _z: float) -> float:
	push_error("SDF.surface_height() not implemented - this field is not a height field")
	return 0.0


## How far the surface reaches away from y = 0, in world units. Drives the
## terrain material's hue ramp.
##
## DERIVED FROM THE FIELD ON PURPOSE. The ramp used to be set from
## `SDFHills.amplitude` directly; copying that number into level data instead
## would sever the tie and go stale the first time the field is retuned, and
## the symptom — a hue ramp that clips or never reaches its peak colour — is
## something no test in the sequence looks at.
func vertical_extent() -> float:
	push_error("SDF.vertical_extent() not implemented - this field is not a height field")
	return 0.0
