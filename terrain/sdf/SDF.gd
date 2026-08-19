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
