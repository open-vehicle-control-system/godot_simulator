// A roof: a tiled roofing texture set whose rows run along the eave, tinted to the roof's own
// colour, with a dark trim along its edge. UV is (metres along the eave, metres up the
// slope); the vertex colour is the roof's albedo, its alpha the distance to the roof's edge
// over EDGE_RANGE_M.
shader_type spatial;
render_mode cull_disabled;

const float EDGE_RANGE_M = 2.0;
const float TRIM_WIDTH_M = 0.18;
const float TRIM_SHADE = 0.45;
// How much of the set's own shading the tint keeps.
const float GRAIN = 0.85;
const float STREAK_SHADE = 0.22;
const float PATCH_SHADE = 0.14;

uniform sampler2D roofing_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D roofing_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D roofing_roughness : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float size_m = 3.0;
uniform vec3 roofing_mean = vec3(0.5);

float hash(vec2 cell) {
	return fract(sin(dot(cell, vec2(127.1, 311.7))) * 43758.5453);
}

float value_noise(vec2 at) {
	vec2 cell = floor(at);
	vec2 within = fract(at);
	within = within * within * (3.0 - 2.0 * within);
	return mix(
		mix(hash(cell), hash(cell + vec2(1.0, 0.0)), within.x),
		mix(hash(cell + vec2(0.0, 1.0)), hash(cell + vec2(1.0, 1.0)), within.x),
		within.y);
}

varying vec3 roof_albedo;
varying float edge_m;
varying vec3 world_position;

void vertex() {
	roof_albedo = COLOR.rgb;
	edge_m = COLOR.a * EDGE_RANGE_M;
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	// The image's top is up the slope.
	vec2 roofing_uv = vec2(UV.x, -UV.y) / size_m;
	vec3 roofing = texture(roofing_albedo, roofing_uv).rgb;
	vec3 grain = mix(vec3(1.0), roofing / max(roofing_mean, vec3(1e-3)), GRAIN);
	// Weather: streaks run down the slope, and no two patches of a roof have aged alike.
	float streaks = value_noise(vec2(UV.x * 1.7, UV.y * 0.12));
	float patches = value_noise(UV * 0.23 + 11.0);
	float weather = 1.0 - STREAK_SHADE * streaks * streaks - PATCH_SHADE * patches;
	float trim = 1.0 - smoothstep(TRIM_WIDTH_M * 0.6, TRIM_WIDTH_M, edge_m);
	ALBEDO = roof_albedo * clamp(grain, 0.0, 3.0) * weather * mix(1.0, TRIM_SHADE, trim);
	ROUGHNESS = texture(roofing_roughness, roofing_uv).r;
	SPECULAR = 0.35;

	// The frame the rows lie in, from how position and UV change across the screen.
	vec3 across = dFdx(world_position);
	vec3 down = dFdy(world_position);
	vec2 uv_across = dFdx(roofing_uv);
	vec2 uv_down = dFdy(roofing_uv);
	vec3 facing = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	vec3 along_rows = across * uv_down.y - down * uv_across.y;
	vec3 up_slope = down * uv_across.x - across * uv_down.x;
	float scale = inversesqrt(max(max(dot(along_rows, along_rows), dot(up_slope, up_slope)), 1e-12));
	// The normal map stores x and y: z is what makes the normal a unit long.
	vec3 bump = vec3(texture(roofing_normal, roofing_uv).rg * 2.0 - 1.0, 0.0);
	bump.z = sqrt(max(1.0 - dot(bump.xy, bump.xy), 0.0));
	vec3 world_normal = normalize(
		along_rows * scale * bump.x + up_slope * scale * bump.y + facing * bump.z);
	NORMAL = normalize((VIEW_MATRIX * vec4(world_normal, 0.0)).xyz);
}
