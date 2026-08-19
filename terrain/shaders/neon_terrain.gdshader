shader_type spatial;

// Neon terrain: a world-space triplanar grid burned into the surface, a
// height-driven hue ramp, and a rim glow. This is the "digital / tron-esque"
// look the README asks for, and it is doing a second job as well - the grid
// lines are the only thing in the frame that shows terrain SHAPE at a glance,
// because the marching-cubes surface is otherwise untextured and reads flat.
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
uniform float line_width : hint_range(0.002, 0.3) = 0.045;

// How bright the lines burn. This is the whole look; below ~1.0 the terrain
// reads as ordinary dark rock.
uniform float emission_strength : hint_range(0.0, 8.0) = 2.4;

// Height over which the hue ramps from grid_color to peak_color. Set to the
// terrain amplitude so the ramp spans the actual hills rather than clipping.
uniform float height_range = 24.0;

// Rim light along silhouettes. Cheap, and it is what makes a crater's lip
// visible from inside the hole.
uniform float rim_strength : hint_range(0.0, 3.0) = 0.9;

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

	// Rim: NORMAL and VIEW are both view-space in fragment, so this needs no
	// extra varying.
	float rim = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), 3.0);

	ALBEDO = mix(base_color, neon * 0.35, lines);
	EMISSION = neon * (lines * emission_strength + rim * rim_strength);
	ROUGHNESS = mix(0.85, 0.25, lines);
	METALLIC = 0.0;
}
