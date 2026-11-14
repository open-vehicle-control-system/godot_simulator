// A building wall: a tiled texture with a tint, and windows drawn in metres. UV is (metres
// along the wall, 1 - metres above the ground) / 3; UV2.x is the wall's height in metres, so
// windows stay below the eaves.
shader_type spatial;
render_mode cull_back;

const int HOUSE = 0;
const int HALL = 1;
const int OFFICE = 2;
const float UV_UNIT_M = 3.0;

uniform sampler2D wall_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D wall_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D wall_roughness : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float size_m = 3.0;
uniform int windows = 0;
uniform vec3 tint : source_color = vec3(1.0);

varying float wall_top_m;

void vertex() {
	wall_top_m = UV2.x;
}

float inside(vec2 at, vec2 low, vec2 high) {
	return step(low.x, at.x) * step(at.x, high.x) * step(low.y, at.y) * step(at.y, high.y);
}

void fragment() {
	vec2 at_m = vec2(UV.x, 1.0 - UV.y) * UV_UNIT_M;
	vec2 wall_uv = at_m / size_m;
	vec3 wall = texture(wall_albedo, wall_uv).rgb * tint;
	// The normal map stores x and y: z is what makes the normal a unit long.
	vec2 stored = texture(wall_normal, wall_uv).rg;
	vec2 leaning = stored * 2.0 - 1.0;
	vec3 normal = vec3(stored, 0.5 + 0.5 * sqrt(max(1.0 - dot(leaning, leaning), 0.0)));
	float roughness = texture(wall_roughness, wall_uv).r;

	float glass = 0.0;
	float frame = 0.0;
	if (windows == HOUSE) {
		vec2 cell = vec2(mod(at_m.x, 3.2), mod(at_m.y, 2.8));
		float allowed = step(0.4, at_m.y) * step(at_m.y + 0.7, wall_top_m);
		frame = inside(cell, vec2(0.95, 0.80), vec2(2.25, 2.25)) * allowed;
		glass = inside(cell, vec2(1.03, 0.88), vec2(2.17, 2.17)) * allowed;
		glass *= 1.0 - inside(cell, vec2(1.57, 0.88), vec2(1.63, 2.17));
	} else if (windows == HALL) {
		float band_from_m = wall_top_m - 1.9;
		float band = step(band_from_m, at_m.y) * step(at_m.y, band_from_m + 1.0) * step(3.0, wall_top_m);
		frame = band;
		glass = band * step(0.06, fract(at_m.x / 1.6)) * step(fract(at_m.x / 1.6), 0.96);
	} else {
		vec2 cell = vec2(mod(at_m.x, 2.7), mod(at_m.y, 3.6));
		float allowed = step(0.6, at_m.y) * step(at_m.y + 0.9, wall_top_m);
		frame = inside(cell, vec2(0.25, 0.85), vec2(2.45, 2.75)) * allowed;
		glass = inside(cell, vec2(0.32, 0.92), vec2(2.38, 2.68)) * allowed;
	}
	vec3 frame_colour = windows == HALL ? vec3(0.2, 0.21, 0.23) : vec3(0.6, 0.6, 0.58);
	vec3 colour = mix(wall, frame_colour, frame);
	colour = mix(colour, vec3(0.02, 0.03, 0.04), glass);
	// Dirt gathers at the foot of a wall.
	colour *= mix(0.72, 1.0, smoothstep(0.0, 1.2, at_m.y));
	ALBEDO = colour;
	ROUGHNESS = mix(mix(roughness, 0.45, frame), 0.06, glass);
	SPECULAR = mix(0.4, 0.8, glass);

	vec3 out_of_wall = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	vec3 along = normalize(cross(vec3(0.0, 1.0, 0.0), out_of_wall) + vec3(1e-4, 0.0, 0.0));
	vec3 up = normalize(cross(out_of_wall, along));
	vec3 bump = normalize(mix(normal, vec3(0.5, 0.5, 1.0), max(frame, glass)) * 2.0 - 1.0);
	vec3 world_normal = normalize(along * bump.x + up * bump.y + out_of_wall * bump.z);
	NORMAL = normalize((VIEW_MATRIX * vec4(world_normal, 0.0)).xyz);
}
