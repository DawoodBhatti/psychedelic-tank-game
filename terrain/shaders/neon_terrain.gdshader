shader_type spatial;

// Neon terrain: a world-space triplanar grid burned into the surface, map-style
// elevation contours over it, a height-driven hue ramp, and a rim glow. This is
// the "digital / tron-esque" look the README asks for, and it is doing a second
// job as well - it is the only thing in the frame that shows terrain SHAPE at a
// glance, because the marching-cubes surface is otherwise untextured and reads
// flat.
//
// The two line families answer different questions and are deliberately not the
// same weight. The grid is triplanar, so it says which way a face is TURNED;
// the contours come from world Y alone, so they say how HIGH it is. The grid on
// its own read as basic, so it is dialled back to sit underneath rather than
// compete.
//
// Grid lines are computed from WORLD position, not UVs. The mesh is generated
// and has no meaningful UVs at all, and world-space projection also means the
// grid does not scale, stretch or reset across a chunk boundary - which is
// exactly what would give the chunk seams away.
//
// The crater is the thing this has to make legible. A hole reads as neon
// against dark, so keep the grid emissive and the base dark: fresh geometry
// inside a crater picks up the same grid, and the eye follows it inwards.

// Lit, not unshaded: the directional light is what separates one slope from
// another, and an unshaded neon world is a flat silhouette with lines on it.
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

uniform vec3 base_color : source_color = vec3(0.02, 0.03, 0.06);
uniform vec3 grid_color : source_color = vec3(0.0, 0.85, 1.0);
uniform vec3 peak_color : source_color = vec3(0.95, 0.15, 0.75);

// World units per grid cell. Wants to be a multiple of the terrain's
// voxel_size or the lines beat against the facets.
uniform float grid_scale = 4.0;

// Fraction of a cell the line occupies, before distance fading.
uniform float line_width : hint_range(0.002, 0.3) = 0.035;

// How bright the lines burn. Deliberately dimmer than the contours below: the
// grid is the substrate that says which way a face is turned, and it competed
// with - and read flatter than - anything drawn on top of it when the two were
// the same weight. Below ~1.0 the terrain reads as ordinary dark rock.
uniform float emission_strength : hint_range(0.0, 8.0) = 1.6;

// Height over which the hue ramps from grid_color to peak_color. Set to the
// terrain amplitude so the ramp spans the actual hills rather than clipping.
uniform float height_range = 24.0;

// Rim light along silhouettes. Cheap, and it is what makes a crater's lip
// visible from inside the hole.
uniform float rim_strength : hint_range(0.0, 3.0) = 0.9;

// --- Contours --------------------------------------------------------------
// Map-style elevation lines, driven by world Y alone. The grid shows which way
// a surface faces; contours show how HIGH it is, which the hue ramp alone only
// says vaguely. Because they come from world Y and nothing else, one line means
// one elevation everywhere in the frame - across a chunk seam, and across the
// fresh wall of a crater.

// World units between minor lines. 4.0 is one voxel pair, so the lines land on
// the facets rather than beating against them. RETUNED WHEN THE WORLD'S RELIEF
// CHANGES - it is a uniform for exactly that reason, so keep it out of the
// shader body.
uniform float contour_interval = 4.0;

// Half-thickness of a minor line, as a fraction of the interval.
uniform float contour_width : hint_range(0.005, 0.3) = 0.05;

// How bright the lines burn, in the same units as emission_strength. Sits just
// ABOVE the grid's, which is the whole point of the pair. It does not want to
// go much higher: the environment tonemaps ACES with glow over it, and at 2.8 a
// measured frame came back 43% desaturated - the lines stopped being lines and
// became a wash.
uniform float contour_strength : hint_range(0.0, 8.0) = 1.8;

// Every Nth line is an index contour, drawn heavier so the eye can count them.
uniform float contour_index_every = 5.0;

// Warm against a cyan/magenta world, which is both the map convention and the
// only hue in the frame that neither the grid nor the height ramp produces.
uniform vec3 contour_color : source_color = vec3(1.0, 0.62, 0.16);

// Index lines get this much extra emission, over a band this fraction of the
// (five times wider) index cell - which works out at about twice the physical
// thickness of a minor line. Weight comes from BOTH, so neither has to be
// large; doubling both at once is what blows an index line out to white.
const float CONTOUR_INDEX_BOOST = 1.6;
const float CONTOUR_INDEX_WIDTH = 0.4;

// --- The trippy half -------------------------------------------------------
// Driven from the game by a single uniform so the whole effect is one number
// to turn off, rather than a shader variant. At 0 this is a static neon grid;
// at 1 the hue cycles and the lines breathe.
uniform float trip_amount : hint_range(0.0, 1.0) = 0.0;
uniform float trip_hue_speed = 0.06;
uniform float trip_pulse_speed = 1.7;
uniform float trip_pulse_scale = 0.02;

varying vec3 v_world_pos;
varying vec3 v_world_normal;

vec3 hue_shift(vec3 colour, float shift) {
	// Rodrigues rotation of the colour vector about the grey axis. Cheaper
	// than a full RGB->HSV->RGB round trip and has no branches, which matters
	// in a fragment shader covering the whole screen.
	const vec3 k = vec3(0.57735027); // normalize(vec3(1.0))
	float angle = shift * 6.2831853;
	float c = cos(angle);
	return colour * c
		+ cross(k, colour) * sin(angle)
		+ k * dot(k, colour) * (1.0 - c);
}

// Distance to the nearest grid line on one plane, in cells, antialiased by the
// screen-space derivative so the lines stay one pixel wide at any distance
// instead of aliasing into noise on the horizon.
float grid_line(vec2 p, float width) {
	vec2 cell = fract(p) - 0.5;
	vec2 d = abs(cell);
	vec2 fw = fwidth(p);
	vec2 line = smoothstep(vec2(width) + fw, vec2(width) - fw, d);
	return clamp(max(line.x, line.y), 0.0, 1.0);
}

// One family of iso-lines through world Y, antialiased by the screen-space
// derivative the same way grid_line() is.
float contour_band(float y, float interval, float width) {
	float f = y / interval;
	float d = abs(fract(f) - 0.5);
	float fw = fwidth(f);
	// Fade out where the lines bunch tighter than they can be drawn - on a near
	// vertical face the spacing collapses and un-faded contours read as noise.
	return smoothstep(width + fw, width - fw, d) * (1.0 - smoothstep(0.35, 0.5, fw));
}

void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec3 wp = v_world_pos / grid_scale;
	vec3 n = normalize(v_world_normal);

	// Triplanar blend. Raised to a power so the transition between projections
	// is tight; a linear blend smears all three grids together on any slope,
	// and a marching-cubes surface is nothing but slopes.
	vec3 blend = pow(abs(n), vec3(4.0));
	blend /= max(blend.x + blend.y + blend.z, 0.0001);

	float width = line_width
		+ trip_amount * trip_pulse_scale * sin(TIME * trip_pulse_speed + v_world_pos.y * 0.05);

	float lines =
		  grid_line(wp.yz, width) * blend.x
		+ grid_line(wp.xz, width) * blend.y
		+ grid_line(wp.xy, width) * blend.z;

	// Height ramp: low ground stays cyan, peaks go magenta. Uses world Y
	// directly, so it is continuous across chunks for the same reason the grid
	// is.
	float h = clamp(v_world_pos.y / height_range * 0.5 + 0.5, 0.0, 1.0);
	vec3 neon = mix(grid_color, peak_color, h);

	neon = mix(neon, hue_shift(neon, TIME * trip_hue_speed), trip_amount);

	// Contours. Guarded divisors: a zero interval on an authored material would
	// otherwise take the whole surface out rather than just the lines.
	float interval = max(contour_interval, 0.001);
	float index_interval = interval * max(contour_index_every, 1.0);
	float minor = contour_band(v_world_pos.y, interval, contour_width);
	// Every index line sits on a minor line, so the two add and the index ones
	// come out heavier without a branch.
	float index = contour_band(v_world_pos.y, index_interval,
		contour_width * CONTOUR_INDEX_WIDTH);
	float contours = minor + index * CONTOUR_INDEX_BOOST;

	// Rim: NORMAL and VIEW are both view-space in fragment, so this needs no
	// extra varying.
	float rim = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), 3.0);

	ALBEDO = mix(base_color, neon * 0.35, lines);
	EMISSION = neon * (lines * emission_strength + rim * rim_strength)
		+ contour_color * contours * contour_strength;
	ROUGHNESS = mix(0.85, 0.25, lines);
	METALLIC = 0.0;
}
