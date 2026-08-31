shader_type spatial;

// A tower, and the cracks that count the hits it has taken.
//
// WHY `damage_amount` IS AN `instance uniform` AND NOT A PLAIN ONE. Six towers
// share one material, and a plain uniform lives on the MATERIAL - so the first
// tower to take a hit would crack all six. The alternative is duplicating the
// ShaderMaterial per tower in _ready(), which works and costs a second place for
// the look to live: a material override written from a script silently outranks
// whatever a swapped-in skin brought with it, which is exactly the arrangement
// SkinSlot's header exists to prevent. An instance uniform writes a PARAMETER
// rather than a material, so a real tower model dropped in later keeps its own
// shader and simply ignores a parameter it does not declare.
//
// THE CRACKS ARE QUANTISED BY THE GAME, NOT HERE. tower.gd rounds the health
// fraction down to whole hits before writing this, so the player can count
// damage rather than watch a continuous ramp. This shader draws whatever number
// it is handed and knows nothing about hit points - which is what lets the
// stages be re-derived from Shell.NOMINAL_DAMAGE without touching any GLSL.
//
// THE LOOK IS THE TERRAIN'S, DELIBERATELY. Same triplanar world-space grid, same
// cyan, same emission-led shading as heightmap_terrain.gdshader, so a tower reads
// as part of this world rather than as an imported box. The crack colour is the
// contour lines' warm orange for the same reason - it is the one hue already in
// the frame that neither the grid nor the height ramp produces, so a crack is
// separable from the terrain behind it on hue as well as on luma.

render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// 0 undamaged, 1 destroyed. Written per tower with
// GeometryInstance3D.set_instance_shader_parameter().
instance uniform float damage_amount : hint_range(0.0, 1.0) = 0.0;

uniform vec3 base_color : source_color = vec3(0.05, 0.06, 0.10);
uniform vec3 edge_color : source_color = vec3(0.0, 0.85, 1.0);

// Cracks and the char around them. Warm, against a cyan/magenta world.
uniform vec3 crack_color : source_color = vec3(1.0, 0.42, 0.10);
uniform vec3 ruin_color : source_color = vec3(0.10, 0.03, 0.02);

// World units per grid cell on the tower's faces. Smaller than the terrain's 4.0
// so the tower carries more lines than the ground it stands on and reads as
// built rather than as extruded landscape.
uniform float grid_scale = 2.0;
uniform float line_width : hint_range(0.002, 0.3) = 0.05;
uniform float emission_strength : hint_range(0.0, 8.0) = 1.5;
uniform float rim_strength : hint_range(0.0, 3.0) = 0.7;

// How bright a fully cracked tower burns along its fractures, and how coarse the
// fracture network is (cells per world unit).
uniform float crack_strength : hint_range(0.0, 16.0) = 7.0;
uniform float crack_scale = 0.42;

// Half-width of the fracture band at damage_amount 0 and 1, as a distance in
// noise units. The first stage has to be VISIBLE, not hinted: at 1/5 damage the
// band is CRACK_WIDTH_MIN + 0.2 * (CRACK_WIDTH_MAX - CRACK_WIDTH_MIN).
const float CRACK_WIDTH_MIN = 0.03;
const float CRACK_WIDTH_MAX = 0.16;

// Damage over which the neon edge lines gutter out. A dead tower keeps its
// silhouette and loses its glow, so "destroyed" is legible without a wreck mesh.
const float EDGE_FADE = 0.9;

varying vec3 v_world_pos;
varying vec3 v_world_normal;

float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

// Value noise: trilinear blend of eight lattice hashes, smoothstepped so the
// isosurface below has no lattice-aligned creases.
float vnoise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);

	float n000 = hash13(i + vec3(0.0, 0.0, 0.0));
	float n100 = hash13(i + vec3(1.0, 0.0, 0.0));
	float n010 = hash13(i + vec3(0.0, 1.0, 0.0));
	float n110 = hash13(i + vec3(1.0, 1.0, 0.0));
	float n001 = hash13(i + vec3(0.0, 0.0, 1.0));
	float n101 = hash13(i + vec3(1.0, 0.0, 1.0));
	float n011 = hash13(i + vec3(0.0, 1.0, 1.0));
	float n111 = hash13(i + vec3(1.0, 1.0, 1.0));

	return mix(
		mix(mix(n000, n100, f.x), mix(n010, n110, f.x), f.y),
		mix(mix(n001, n101, f.x), mix(n011, n111, f.x), f.y),
		f.z);
}

// Distance to the nearest grid line on one plane, in cells, antialiased by the
// screen-space derivative so the lines stay about a pixel wide at any distance
// instead of aliasing into noise across the glen.
float grid_line(vec2 p, float width) {
	vec2 cell = fract(p) - 0.5;
	vec2 d = abs(cell);
	vec2 fw = fwidth(p);
	vec2 line = smoothstep(vec2(width) + fw, vec2(width) - fw, d);
	return clamp(max(line.x, line.y), 0.0, 1.0);
}

void vertex() {
	// MODEL_NORMAL_MATRIX, not MODEL_MATRIX's basis: the spawner gives each tower
	// a random yaw, and a normal pushed through the model matrix directly would
	// be wrong the moment anything non-uniform is scaled into that transform. It
	// is also not NORMAL_MATRIX, which is not a Godot 4 built-in at all - the
	// first version of this shader used that name and failed to compile, which
	// headless DID report rather than hiding.
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
}

void fragment() {
	float dmg = clamp(damage_amount, 0.0, 1.0);
	vec3 n = normalize(v_world_normal);

	// Triplanar blend, raised to a power so each face gets one projection rather
	// than a smear of all three.
	vec3 blend = pow(abs(n), vec3(4.0));
	blend /= max(blend.x + blend.y + blend.z, 0.0001);

	vec3 wp = v_world_pos / grid_scale;
	float lines =
		  grid_line(wp.yz, line_width) * blend.x
		+ grid_line(wp.xz, line_width) * blend.y
		+ grid_line(wp.xy, line_width) * blend.z;

	// FRACTURES AS AN ISOSURFACE, not as a texture. The set of points where the
	// noise crosses 0.5 is a connected branching network - which is what a crack
	// pattern is - and widening the band around it is how a hairline becomes a
	// split without the pattern moving between stages. The stages then look like
	// the SAME damage getting worse rather than like five unrelated overlays.
	float noise = vnoise(v_world_pos * crack_scale);
	float width = mix(CRACK_WIDTH_MIN, CRACK_WIDTH_MAX, dmg);
	float crack = 1.0 - smoothstep(0.0, width, abs(noise - 0.5));
	// An undamaged tower has no cracks at all, and the first stage arrives at
	// full weight rather than fading in from nothing.
	crack *= smoothstep(0.0, 0.08, dmg);

	// Neon guttering out as the tower dies. It reaches zero at EDGE_FADE, so the
	// last stage before death still glows and the wreck does not.
	float glow = 1.0 - smoothstep(0.0, EDGE_FADE, dmg);

	float rim = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), 3.0);

	vec3 body = mix(base_color, ruin_color, dmg);
	ALBEDO = mix(body, edge_color * 0.3 * glow, lines);
	EMISSION = edge_color * glow * (lines * emission_strength + rim * rim_strength)
		+ crack_color * crack * crack_strength * dmg;
	ROUGHNESS = mix(0.9, 0.35, lines * glow);
	METALLIC = 0.0;
}
