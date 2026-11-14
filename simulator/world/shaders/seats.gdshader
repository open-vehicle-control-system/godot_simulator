// Grandstand seating: concrete steps with rows of seats, gaps between seats and stair aisles.
// UV is (metres along the stand, 1 - metres of depth from the front); UV2 is (row depth in
// metres, 1 - face kind: 0 tread, 1 riser, 2 plain concrete).
shader_type spatial;
render_mode cull_back;

const float AISLE_EVERY_M = 22.0;
const float AISLE_WIDTH_M = 1.4;
const float SEAT_WIDTH_M = 0.5;
const float CONCRETE_SIZE_M = 4.0;

uniform sampler2D concrete_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D concrete_roughness : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec3 tint : source_color = vec3(0.45, 0.04, 0.035);

varying float row_depth_m;
varying float face_kind;

void vertex() {
	row_depth_m = max(UV2.x, 0.3);
	face_kind = 1.0 - UV2.y;
}

void fragment() {
	vec2 at_m = vec2(UV.x, 1.0 - UV.y);
	vec3 concrete = texture(concrete_albedo, at_m / CONCRETE_SIZE_M).rgb;
	float roughness = texture(concrete_roughness, at_m / CONCRETE_SIZE_M).r;
	float kind = round(face_kind);
	float aisle = 1.0 - step(AISLE_WIDTH_M, mod(at_m.x, AISLE_EVERY_M));
	float gap = 1.0 - step(0.07, fract(at_m.x / SEAT_WIDTH_M));
	float seat = 0.0;
	vec3 seat_colour = tint;
	if (kind < 0.5) {
		float across_row = fract(at_m.y / row_depth_m);
		seat = step(0.38, across_row) * step(across_row, 0.96);
		seat_colour *= mix(0.8, 1.1, smoothstep(0.38, 0.96, across_row));
	} else if (kind < 1.5) {
		seat = 1.0;
		seat_colour *= 0.85;
	}
	seat *= (1.0 - aisle) * (1.0 - gap);
	ALBEDO = mix(concrete, seat_colour, seat);
	ROUGHNESS = mix(roughness, 0.45, seat);
	SPECULAR = mix(0.4, 0.6, seat);
}
