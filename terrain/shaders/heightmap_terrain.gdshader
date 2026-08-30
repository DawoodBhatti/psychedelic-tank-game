shader_type spatial;

// Neon terrain, displaced. The fragment half is neon_terrain.gdshader's, kept
// deliberately identical so the world looks the same after the renderer changed
// underneath it; the vertex half is what makes a flat grid into a glen.
//
// WHY THIS IS A SEPARATE SHADER AND NOT A FLAG ON THAT ONE. That shader draws a
// marching-cubes surface, which arrives already shaped, with one flat normal per
// facet. This one draws a geometry clipmap: every vertex reaches y = 0 and has
// to be lifted onto the height field, and the normal has to be derived rather
// than read. The two vertex stages have nothing in common, and a `displace`
// uniform branching between them would be a shader variant pretending to be a
// number. WHILE BOTH EXIST, THE FRAGMENT HALVES HAVE TO BE RETUNED TOGETHER -
// the voxel renderer is unused but kept, so this is a real cost and it is
// written down rather than discovered.
//
// The two line families answer different questions and are deliberately not the
// same weight. The grid is triplanar, so it says which way a face is TURNED;
// the contours come from world Y alone, so they say how HIGH it is.
//
// Grid lines are computed from WORLD position, not UVs. The mesh is a bare grid
// with no meaningful UVs at all, and world-space projection also means the grid
// does not slide when the clipmap re-snaps under the player - which is exactly
// what would give the ring motion away.

render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// --- The height field ------------------------------------------------------
// A single-channel FLOAT texture of WORLD HEIGHTS, built once at load by
// HeightmapTerrain from field.ground.surface_height(). It is not a normalised
// heightmap and there is no mapping to apply: what is in the texel is the y
// the vertex goes to.
//
// THAT IS THE POINT. The collider is built from the same numbers, so the ground
// you see and the ground you drive on are the same array rather than two
// implementations of one formula. Re-deriving SDFHeightmap's elevation mapping
// in GLSL would have added a second copy to drift, plus an sRGB and a bit-depth
// question about how a texture read compares with Image.get_pixel().
//
// Read with texelFetch and interpolated by hand below, so no sampler state -
// filter, repeat, mipmaps - can change the answer.
uniform sampler2D height_map : hint_default_black, filter_nearest, repeat_disable;

// World x/z of texel (0, 0), world units per texel, and the texel counts.
uniform vec2 map_origin = vec2(0.0);
uniform vec2 map_step = vec2(2.0);
uniform ivec2 map_dim = ivec2(2);

// Half-width of the central difference the normal is built from, in world
// units. Set from HeightmapTerrain.normal_epsilon, which is also
// TerrainAnalysis.slope_step, so "slope" means one thing across the project.
uniform float normal_epsilon = 2.0;

uniform vec3 base_color : source_color = vec3(0.02, 0.03, 0.06);
uniform vec3 grid_color : source_color = vec3(0.0, 0.85, 1.0);
uniform vec3 peak_color : source_color = vec3(0.95, 0.15, 0.75);

// World units per grid cell. Wants to be a multiple of the clipmap's
// base_spacing or the lines beat against the quads.
uniform float grid_scale = 4.0;

// Fraction of a cell the line occupies, before distance fading.
uniform float line_width : hint_range(0.002, 0.3) = 0.035;

// How bright the lines burn. Deliberately dimmer than the contours below: the
// grid is the substrate that says which way a face is turned, and it competed
// with - and read flatter than - anything drawn on top of it when the two were
// the same weight.
uniform float emission_strength : hint_range(0.0, 8.0) = 1.6;

// Height over which the hue ramps from grid_color to peak_color. Set from the
// game to the field's own vertical_extent(), so the ramp spans the actual glen
// rather than clipping - and so it follows height_scale automatically.
uniform float height_range = 24.0;

// Rim light along silhouettes.
uniform float rim_strength : hint_range(0.0, 3.0) = 0.9;

// --- Contours --------------------------------------------------------------
// Map-style elevation lines, driven by world Y alone. Because they come from
// world Y and nothing else, one line means one elevation everywhere in the
// frame - across a ring boundary as much as anywhere else.

// World units between minor lines. RETUNED WITH THE WORLD'S RELIEF, which is
// why it is a uniform: it is the interval divided by the relief that decides how
// many lines are in the frame, and S3 multiplied both the footprint and
// height_scale by ~5.27.
uniform float contour_interval = 20.0;

// Half-thickness of a minor line, as a fraction of the interval.
uniform float contour_width : hint_range(0.005, 0.3) = 0.05;

// How bright the lines burn, in the same units as emission_strength. Sits just
// ABOVE the grid's, which is the whole point of the pair.
uniform float contour_strength : hint_range(0.0, 8.0) = 1.8;

// Every Nth line is an index contour, drawn heavier so the eye can count them.
uniform float contour_index_every = 5.0;

// Warm against a cyan/magenta world, which is both the map convention and the
// only hue in the frame that neither the grid nor the height ramp produces.
uniform vec3 contour_color : source_color = vec3(1.0, 0.62, 0.16);

// Index lines get this much extra emission, over a band this fraction of the
// (five times wider) index cell. Weight comes from BOTH, so neither has to be
// large.
const float CONTOUR_INDEX_BOOST = 1.6;
const float CONTOUR_INDEX_WIDTH = 0.4;

// THERE IS NO CONTOUR LINE ON FLAT GROUND, which is both what a real contour map
// does and the fix for an artifact this look had on the valley floor: where the
// surface is near-horizontal, world Y barely changes per pixel, fwidth() in
// contour_band() collapses, its smoothstep becomes a hard step, and a whole
// region flips lit/unlit as sub-quad height variation crosses the threshold.
// The fade below removes the line rather than antialiasing a band with no
// gradient to antialias against.
//
// RE-MEASURED FOR THIS RENDERER, NOT INHERITED - AND THE MEASUREMENT SAID KEEP
// THEM, which is a different statement from not having looked.
//
// The voxel version's 0.003/0.012 were calibrated against marching-cubes facet
// normals, which are flat per triangle: the valley floor there measured
// 1 - |n.y| of exactly 0.0000 (three facets literally constant in world Y)
// against hillsides at 0.0140-0.2295. A displaced grid produces CONTINUOUS
// normals, so that degenerate flat population had to be re-derived rather than
// assumed to survive.
//
// MEASURED 2026-08-30 over 1600 points across the footprint, with
// HeightmapTerrain.surface_relief_quantiles():
//     min 0.00000   p25 0.00364   p50 0.02758   p75 0.05321   max 0.44616
// Corroborated off a path that does not share a line of code with it -
// TerrainAnalysis's slope_degrees over 400 jittered candidates, computed from
// field.ground.surface_height() rather than from this texture: p25 4.912 deg
// and p50 13.488 deg, whose 1 - cos are 0.00367 and 0.02757. Three significant
// figures on both.
//
// So 0.003 still sits inside the flattest quarter and 0.012 still sits in the
// gap between that quarter and the median. In angle, lines vanish below
// ~4.4 degrees and are at full weight above ~8.9. THE REASON THE POPULATIONS
// DID NOT MOVE is that S3 scaled height_scale with world_size, which holds
// every gradient in the glen fixed by construction - max_world_gradient read
// 1.89054 before and 1.89957 after.
const float CONTOUR_RELIEF_MIN = 0.003;
const float CONTOUR_RELIEF_FULL = 0.012;

// --- The trippy half -------------------------------------------------------
uniform float trip_amount : hint_range(0.0, 1.0) = 0.0;
uniform float trip_hue_speed = 0.06;
uniform float trip_pulse_speed = 1.7;
uniform float trip_pulse_scale = 0.02;

varying vec3 v_world_pos;
varying vec3 v_world_normal;

// Bilinear read of the height grid with the edges EXTENDED, which is what
// SDFHeightmap.surface_height() does outside its raster and what
// HeightmapTerrain._texture_height() does on the CPU. Extending rather than
// wrapping is what gives the outermost ring flat ground running to the horizon
// instead of a second copy of the glen or a void.
float map_height(vec2 world_xz) {
	vec2 t = clamp((world_xz - map_origin) / map_step, vec2(0.0), vec2(map_dim - 1));
	ivec2 i0 = ivec2(floor(t));
	ivec2 i1 = min(i0 + 1, map_dim - 1);
	vec2 f = t - vec2(i0);

	float h00 = texelFetch(height_map, ivec2(i0.x, i0.y), 0).r;
	float h10 = texelFetch(height_map, ivec2(i1.x, i0.y), 0).r;
	float h01 = texelFetch(height_map, ivec2(i0.x, i1.y), 0).r;
	float h11 = texelFetch(height_map, ivec2(i1.x, i1.y), 0).r;

	return mix(mix(h00, h10, f.x), mix(h01, h11, f.x), f.y);
}

vec3 hue_shift(vec3 colour, float shift) {
	// Rodrigues rotation of the colour vector about the grey axis. Cheaper than
	// a full RGB->HSV->RGB round trip and has no branches.
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

// One family of iso-lines through world Y.
float contour_band(float y, float interval, float width) {
	float f = y / interval;
	float d = abs(fract(f) - 0.5);
	float fw = fwidth(f);
	// Fade out where the lines bunch tighter than they can be drawn - on a near
	// vertical face the spacing collapses and un-faded contours read as noise.
	return smoothstep(width + fw, width - fw, d) * (1.0 - smoothstep(0.35, 0.5, fw));
}

void vertex() {
	// THE MODEL TRANSFORM IS A PURE TRANSLATION AND HEIGHTMAP_TERRAIN.GD
	// GUARANTEES IT - it only ever writes .position on a ring. That is what
	// lets the world position be recovered with an add rather than a matrix
	// multiply, and the normal be handed back without an inverse-transpose.
	vec3 origin = MODEL_MATRIX[3].xyz;
	vec3 world = VERTEX + origin;

	world.y = map_height(world.xz);

	// Central difference at a FIXED world epsilon, not at the ring's own quad
	// size: a normal derived per-ring would change across a ring boundary and
	// pop the shading exactly where the seam is.
	float e = normal_epsilon;
	float dx = map_height(world.xz + vec2(e, 0.0)) - map_height(world.xz - vec2(e, 0.0));
	float dz = map_height(world.xz + vec2(0.0, e)) - map_height(world.xz - vec2(0.0, e));
	vec3 n = normalize(vec3(-dx / (2.0 * e), 1.0, -dz / (2.0 * e)));

	VERTEX = world - origin;
	NORMAL = n;

	v_world_pos = world;
	v_world_normal = n;
}

void fragment() {
	vec3 wp = v_world_pos / grid_scale;
	vec3 n = normalize(v_world_normal);

	// Triplanar blend. Raised to a power so the transition between projections
	// is tight; a linear blend smears all three grids together on any slope.
	vec3 blend = pow(abs(n), vec3(4.0));
	blend /= max(blend.x + blend.y + blend.z, 0.0001);

	float width = line_width
		+ trip_amount * trip_pulse_scale * sin(TIME * trip_pulse_speed + v_world_pos.y * 0.05);

	float lines =
		  grid_line(wp.yz, width) * blend.x
		+ grid_line(wp.xz, width) * blend.y
		+ grid_line(wp.xy, width) * blend.z;

	// Height ramp: low ground stays cyan, peaks go magenta. Uses world Y
	// directly, so it is continuous across ring boundaries for the same reason
	// the grid is.
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
	// Both families fade together: an index line on flat ground is the same
	// artifact, only heavier. See CONTOUR_RELIEF_MIN.
	contours *= smoothstep(CONTOUR_RELIEF_MIN, CONTOUR_RELIEF_FULL,
		1.0 - abs(n.y));

	// Rim: NORMAL and VIEW are both view-space in fragment, so this needs no
	// extra varying.
	float rim = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), 3.0);

	ALBEDO = mix(base_color, neon * 0.35, lines);
	EMISSION = neon * (lines * emission_strength + rim * rim_strength)
		+ contour_color * contours * contour_strength;
	ROUGHNESS = mix(0.85, 0.25, lines);
	METALLIC = 0.0;
}
