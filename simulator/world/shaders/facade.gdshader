// A building wall: a tiled texture with a tint; windows in rows a storey apart and a door,
// drawn in metres and centred on the wall. UV is (metres along the wall from its corner,
// 1 - metres above its ground floor) / 3; UV2 is (the wall's top above its ground floor, the
// wall's length) in metres, so windows stay below the eaves and clear of the corners.
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

const float HOUSE_BAY_M = 3.2;
const float HOUSE_STOREY_M = 3.0;
const float OFFICE_BAY_M = 2.7;
const float OFFICE_STOREY_M = 3.6;
const float HALL_PANE_M = 1.6;
const float HALL_MARGIN_M = 0.8;
const float HALL_DOOR_M = 3.6;
const float HALL_BAND_MAX_SLOPE = 0.15;
// The share of walls that have a door, long enough for one.
const float DOOR_SHARE = 0.4;

varying float wall_top_m;
varying flat float wall_length_m;

void vertex() {
	wall_top_m = UV2.x;
	wall_length_m = UV2.y;
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
	float door = 0.0;
	// A number of the wall's own, the same all over it.
	float picked = fract(sin(wall_length_m * 12.9898) * 43758.5453);
	if (windows == HALL) {
		float band_from_m = wall_top_m - 1.9;
		float band = step(band_from_m, at_m.y) * step(at_m.y, band_from_m + 1.0) * step(3.0, wall_top_m);
		band *= step(HALL_MARGIN_M, at_m.x) * step(at_m.x, wall_length_m - HALL_MARGIN_M);
		// A gable end's top slopes: a band hung from it would slope too.
		float top_slope = length(vec2(dFdx(wall_top_m), dFdy(wall_top_m))) / max(length(vec2(dFdx(at_m.x), dFdy(at_m.x))), 1e-6);
		band *= step(top_slope, HALL_BAND_MAX_SLOPE);
		float pane = fract((at_m.x - HALL_MARGIN_M) / HALL_PANE_M);
		frame = band;
		glass = band * step(0.06, pane) * step(pane, 0.96);
		float from_middle_m = abs(at_m.x - wall_length_m * 0.5);
		float has_door = step(picked, DOOR_SHARE) * step(HALL_DOOR_M * 2.0, wall_length_m) * step(4.5, wall_top_m);
		door = has_door * step(from_middle_m, HALL_DOOR_M * 0.5) * step(0.0, at_m.y) * step(at_m.y, 3.6);
	} else {
		float bay_m = windows == HOUSE ? HOUSE_BAY_M : OFFICE_BAY_M;
		float storey_m = windows == HOUSE ? HOUSE_STOREY_M : OFFICE_STOREY_M;
		float bays = max(floor(wall_length_m / bay_m), step(2.0, wall_length_m));
		float from_first_m = at_m.x - (wall_length_m - bays * bay_m) * 0.5;
		float bay = floor(from_first_m / bay_m);
		float storey = floor(at_m.y / storey_m);
		vec2 cell = vec2(from_first_m - bay * bay_m, at_m.y - storey * storey_m);
		float allowed = step(0.0, bay) * step(bay, bays - 0.5) * step(0.0, at_m.y);
		float has_door = step(picked, DOOR_SHARE) * step(1.0, bays) * step(2.6, wall_top_m);
		float at_door = has_door * step(abs(bay - floor(bays * 0.5)), 0.5) * step(abs(storey), 0.5);
		if (windows == HOUSE) {
			float fits = step((storey + 1.0) * storey_m - 0.3, wall_top_m) * (1.0 - at_door);
			frame = inside(cell, vec2(0.95, 0.90), vec2(2.25, 2.35)) * allowed * fits;
			glass = inside(cell, vec2(1.03, 0.98), vec2(2.17, 2.27)) * allowed * fits;
			glass *= 1.0 - inside(cell, vec2(1.57, 0.98), vec2(1.63, 2.27));
			door = inside(cell, vec2(1.1, 0.0), vec2(2.1, 2.1)) * allowed * at_door;
		} else {
			float fits = step((storey + 1.0) * storey_m - 0.4, wall_top_m) * (1.0 - at_door);
			frame = inside(cell, vec2(0.25, 0.85), vec2(2.45, 2.75)) * allowed * fits;
			glass = inside(cell, vec2(0.32, 0.92), vec2(2.38, 2.68)) * allowed * fits;
			frame = max(frame, inside(cell, vec2(0.35, 0.0), vec2(2.35, 2.4)) * allowed * at_door);
			glass = max(glass, inside(cell, vec2(0.43, 0.08), vec2(2.27, 2.32)) * allowed * at_door);
			glass *= 1.0 - at_door * inside(cell, vec2(1.32, 0.0), vec2(1.38, 2.4));
		}
	}
	vec3 frame_colour = windows == HALL ? vec3(0.2, 0.21, 0.23) : vec3(0.6, 0.6, 0.58);
	vec3 colour = mix(wall, frame_colour, frame);
	colour = mix(colour, vec3(0.02, 0.03, 0.04), glass);
	vec3 door_colour = windows == HALL ? vec3(0.45, 0.47, 0.5) * (0.85 + 0.15 * step(0.08, fract(at_m.y / 0.6))) : vec3(0.1, 0.07, 0.05);
	colour = mix(colour, door_colour, door);
	frame = max(frame, door);
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
