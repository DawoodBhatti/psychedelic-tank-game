extends SDF
class_name SDFHills

# The undulating ground the whole level sits on: layered value noise turned
# into a height, then subtracted from p.y so that below the surface is
# NEGATIVE (solid) and above it is positive (air). That sign convention is
# chunk.gd's - it sets a corner bit when the sample is < iso - and every SDF in
# this project has to match it.
#
# It is a heightmap dressed as a distance field, which is deliberate: hills are
# the cheapest possible thing to author, and the moment craters are subtracted
# from it (see TerrainField) the result stops being a heightmap and becomes
# something with overhangs, caves and holes you can see daylight through. The
# heightmap is the starting shape, not the representation.

# DECLARED FIRST, AND THAT IS LOAD-BEARING. `frequency` and `noise_seed` below
# write straight through to this object from their setters, and a setter fires
# during construction when the member initialiser runs. Declared after them,
# this would still be null at that moment and every load would push a nil
# error.
var _noise := FastNoiseLite.new()

## Scales the noise into world units. NOT the peak-to-trough height: layered
## fBm does not saturate to +/-1, so the realised relief is roughly 0.8x this.
## Measured at the default settings over the whole 192m world footprint,
## amplitude 22 gives min -9.74, max +7.50, mean |height| 2.72
## (`Terrain.surface_height_range()`), i.e. 17m of relief, not 22.
##
## Do not sample three points and infer the range from them: Perlin is exactly
## zero at every integer lattice point, so the origin reads as flat ground on
## terrain that is not.
@export var amplitude: float = 22.0

## Roughly the inverse of hill width. Lower is smoother and wider.
##
## Written through to the noise object by the setter rather than applied in
## _init(), because _init() runs BEFORE the loader assigns exported values: the
## parent project shipped a heightmap SDF that configured its noise in _init()
## and therefore ignored every tuned value in the .tres that referenced it,
## silently, while looking entirely correct.
@export var frequency: float = 0.011:
	set(value):
		frequency = value
		_noise.frequency = value

## Changes the landscape and nothing else.
@export var noise_seed: int = 1337:
	set(value):
		noise_seed = value
		_noise.seed = value

## How many octaves of noise are layered.
@export var octaves: int = 4

## How much each successive octave contributes. Below 0.5 keeps the surface
## drivable; at 0.7+ it grows spikes a tank cannot climb.
@export var persistence: float = 0.42

## Pulls the height towards flat steps. 0 is smooth hills, 1 is hard terraces.
## A little of this is what makes the terrain read as built rather than eroded,
## which suits the neon look.
@export var plateau_strength: float = 0.25

## Height of one step, when plateau_strength is above 0.
@export var plateau_step: float = 6.0

## Shifts the whole surface up or down. The chunk grid is built around y = 0,
## so leaving this at 0 centres the terrain in the sampled volume.
@export var vertical_offset: float = 0.0


# Only the one property no export can overwrite. Everything else is applied by
# its own setter, so this cannot go stale the way an _init() full of assignments
# does.
func _init() -> void:
	_noise.noise_type = FastNoiseLite.TYPE_PERLIN


func _fbm(x: float, z: float) -> float:
	var total := 0.0
	var amp := 1.0
	var freq := 1.0

	for _i in octaves:
		total += _noise.get_noise_2d(x * freq, z * freq) * amp
		freq *= 2.0
		amp *= persistence

	return total


## Surface height at a world x/z. Public because spawning anything on the
## ground needs it, and ray-marching the field down from the sky to find the
## same number would cost hundreds of samples for a value the generator already
## knows in closed form.
##
## It ignores craters, by construction - it is the height of the ORIGINAL
## ground. Anything that must not spawn inside a hole should raycast against
## the terrain's collision instead.
func surface_height(x: float, z: float) -> float:
	var n := _fbm(x, z)

	if plateau_strength > 0.0 and plateau_step > 0.0:
		# Quantise in WORLD units and convert back, so plateau_step means a
		# height in metres rather than a fraction of the noise range - the
		# latter changes meaning every time amplitude is retuned.
		var stepped := floorf(n * amplitude / plateau_step) * plateau_step / amplitude
		n = lerpf(n, stepped, plateau_strength)

	return n * amplitude + vertical_offset


func sample(p: Vector3, _chunk_offset: Vector3 = Vector3.ZERO) -> float:
	return p.y - surface_height(p.x, p.z)
