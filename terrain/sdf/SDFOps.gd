class_name SDFOps

# Shared vocabulary of signed-distance primitives, combinators and domain
# operations, used to compose terrain archetypes (see SDFs/archetypes/).
#
# Sign convention matches the rest of the generator: NEGATIVE is inside/solid,
# positive is air, and the isosurface sits at iso_level (0 by default, see
# chunk.gd's _march_cell, which sets a corner bit when d < iso).
#
# Everything here is a static function on plain floats/Vector3s rather than a
# tree of SDF node objects. An expression tree would read better, but sample()
# runs ~227k times per chunk and every node would cost a virtual call on each
# of those; archetypes therefore compose these by hand in a flat sample() and
# inline the innermost loops where it matters.
#
# LIPSCHITZ NOTE: empty-space skipping (planned next) needs |grad d| <= 1 so a
# returned distance is a safe step. Preserved by: all primitives here, union,
# intersect, subtract, onion, round, mirror, repeat, rotate, translate.
# BROKEN by: twist_y (grows with radius), any multiply of the result, and
# noise displacement (bounded by the noise's own gradient). Where an archetype
# uses those it records a `lipschitz` factor for the skip test to divide by.


# ---------------------------------------------------------
# Primitives — all centred on the origin. Translate by offsetting p.
# ---------------------------------------------------------

static func sphere(p: Vector3, r: float) -> float:
	return p.length() - r


static func box(p: Vector3, b: Vector3) -> float:
	var q := p.abs() - b
	var outside := Vector3(maxf(q.x, 0.0), maxf(q.y, 0.0), maxf(q.z, 0.0))
	return outside.length() + minf(maxf(q.x, maxf(q.y, q.z)), 0.0)


static func round_box(p: Vector3, b: Vector3, r: float) -> float:
	return box(p, b - Vector3(r, r, r)) - r


# Squashed sphere. Exact only for a uniform scale, so the result is divided by
# the largest axis scale to stay conservative (never over-reports distance).
static func ellipsoid(p: Vector3, radii: Vector3) -> float:
	var k0 := Vector3(p.x / radii.x, p.y / radii.y, p.z / radii.z).length()
	if k0 == 0.0:
		return -minf(radii.x, minf(radii.y, radii.z))
	var k1 := Vector3(p.x / (radii.x * radii.x), p.y / (radii.y * radii.y), p.z / (radii.z * radii.z)).length()
	return k0 * (k0 - 1.0) / k1


# Capped cylinders. `h` is the half-length along the axis.
static func cylinder_y(p: Vector3, r: float, h: float) -> float:
	var dx := Vector2(p.x, p.z).length() - r
	var dy := absf(p.y) - h
	return minf(maxf(dx, dy), 0.0) + Vector2(maxf(dx, 0.0), maxf(dy, 0.0)).length()


static func cylinder_x(p: Vector3, r: float, h: float) -> float:
	return cylinder_y(Vector3(p.y, p.x, p.z), r, h)


static func cylinder_z(p: Vector3, r: float, h: float) -> float:
	return cylinder_y(Vector3(p.x, p.z, p.y), r, h)


static func torus_xz(p: Vector3, major: float, minor: float) -> float:
	var q := Vector2(Vector2(p.x, p.z).length() - major, p.y)
	return q.length() - minor


# Half-space, solid below y = h.
static func plane_y(p: Vector3, h: float) -> float:
	return p.y - h


# ---------------------------------------------------------
# Combinators
# ---------------------------------------------------------

static func op_union(a: float, b: float) -> float:
	return minf(a, b)


static func op_intersect(a: float, b: float) -> float:
	return maxf(a, b)


# Everything in `a` that is not also in `b`.
static func op_subtract(a: float, b: float) -> float:
	return maxf(a, -b)


# Polynomial smooth minimum (Quilez). `k` is the blend radius in world units;
# k -> 0 degrades to the hard version.
static func op_smooth_union(a: float, b: float, k: float) -> float:
	var h := clampf(0.5 + 0.5 * (b - a) / k, 0.0, 1.0)
	return lerpf(b, a, h) - k * h * (1.0 - h)


static func op_smooth_subtract(a: float, b: float, k: float) -> float:
	var h := clampf(0.5 - 0.5 * (b + a) / k, 0.0, 1.0)
	return lerpf(a, -b, h) + k * h * (1.0 - h)


static func op_smooth_intersect(a: float, b: float, k: float) -> float:
	var h := clampf(0.5 - 0.5 * (b - a) / k, 0.0, 1.0)
	return lerpf(b, a, h) + k * h * (1.0 - h)


# ---------------------------------------------------------
# Shaping — applied to a distance, not a point
# ---------------------------------------------------------

# Hollows a solid into a shell of the given thickness: the interior becomes
# air, so the result is something you can fly inside.
static func op_onion(d: float, thickness: float) -> float:
	return absf(d) - thickness


# Inflates by r, rounding off convex edges.
static func op_round(d: float, r: float) -> float:
	return d - r


# Quantises a height into flat steps, giving stacked-plateau cliffs.
static func op_terrace(y: float, step_height: float) -> float:
	if step_height <= 0.0:
		return y
	return floor(y / step_height) * step_height


# ---------------------------------------------------------
# Domain operations — applied to a point, before evaluating a primitive
# ---------------------------------------------------------

# Mirrors the -X half onto +X, so one primitive yields a symmetric pair.
static func dom_mirror_x(p: Vector3) -> Vector3:
	return Vector3(absf(p.x), p.y, p.z)


# Tiles space, so one primitive becomes an infinite grid of them.
static func dom_repeat_axis(v: float, c: float) -> float:
	if c <= 0.0:
		return v
	return fposmod(v + 0.5 * c, c) - 0.5 * c


static func dom_repeat(p: Vector3, c: Vector3) -> Vector3:
	return Vector3(
		dom_repeat_axis(p.x, c.x),
		dom_repeat_axis(p.y, c.y),
		dom_repeat_axis(p.z, c.z)
	)


static func dom_rotate_y(p: Vector3, angle: float) -> Vector3:
	var s := sin(angle)
	var c := cos(angle)
	return Vector3(c * p.x - s * p.z, p.y, s * p.x + c * p.z)


# Corkscrews the domain about Y — rotation amount grows with height.
# Not distance-preserving; see the Lipschitz note at the top.
static func dom_twist_y(p: Vector3, k: float) -> Vector3:
	return dom_rotate_y(p, k * p.y)
