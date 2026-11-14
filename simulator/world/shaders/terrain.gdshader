// The terrain surface: the ground's layers under the orthophoto and what the pack lays on
// it. On the ground a track map covers, what the road lines image places along the lap:
// white edge lines, red and white kerbs, and the rubber laid on the racing line. On the
// ground a roads map covers, the roads around the lap: their surface, colour and markings.
// On the ground a lots map covers, the parking lots: their surface, colour and bays. UV is
// the orthophoto's.
shader_type spatial;
render_mode cull_back;

#include "ground.gdshaderinc"

const float BORDER_SHARPNESS = 4.0;
const float BORDER_WOBBLE_PX = 0.6;
const float ALONG_UNIT_M = 0.125;
const float RIGHT_UNIT_M = 0.01;
const float RIGHT_ZERO = 2048.0;
const float OFF_ROAD = 4095.0;
// Texels of a road map further apart along the road than this are not on one stretch of it.
const float SEAM_M = 8.0;
const float NO_WRAP_M = 1e9;
const int ROAD_LINES = 6;
const float ROAD_COLOUR_LANES = 16.0;
const float ROAD_ROWS = 24.0;
const float OFFSET_ZERO = 32768.0;
const float ENDS_UNIT_M = 0.05;
const int DOUBLE_LINE = 254;
const int STOP_LINE = 1;
const int CROSSING = 2;
// A give-way line's triangles point at the traffic that gives way: along the road, or against.
const int GIVE_WAY_LINE = 3;
const int GIVE_WAY_LINE_AGAINST = 4;
const float GIVE_WAY_BASE_M = 0.5;
const float GIVE_WAY_HEIGHT_M = 0.6;
const float GIVE_WAY_PITCH_M = 0.75;
const float STOP_LINE_WIDTH_M = 0.5;
const float CROSSING_STRIPE_M = 0.5;
const float LOT_EDGE_UNIT_M = 0.025;
const float LOT_EDGE_ZERO = 128.0;
const float LOT_OUTSIDE_M = 3.0;
const int LOT_HEADER_TEXELS = 3;
const int MAX_LOT_ROWS = 16;
const float BAY_LINE_WIDTH_M = 0.12;
const float LOT_VARIATION = 0.12;
const float JOINT_WIDTH_M = 0.03;
const float PAINT_ROUGHNESS = 0.72;
const float EDGE_UNIT_M = 0.001;
const float RACING_LINE_UNIT_M = 0.05;
const float KERB_UNIT_M = 0.01;
const float LINE_INSET_M = 0.1;
const float MAX_SOFT_M = 0.25;
const float PHOTO_CLEAR_OF_EDGE_M = 1.3;
const float ROAD_GREYING = 0.8;
// The upward part of the normal where a face starts to count as steep, and where it fully is.
const float STEEP_FROM = 0.92;
const float STEEP_AT = 0.78;
const float LINE_WIDTH_M = 0.15;
const float KERB_STRIPE_M = 1.5;
const float RUBBER_HALF_WIDTH_M = 1.5;
const vec3 LINE_WHITE = vec3(0.62);
const vec3 KERB_RED = vec3(0.42, 0.035, 0.03);
const vec3 KERB_WHITE = vec3(0.6, 0.6, 0.58);

uniform sampler2D track_map : filter_nearest, repeat_disable;
uniform sampler2D roads_map : filter_nearest, repeat_disable;
uniform sampler2D lots_map : filter_nearest, repeat_disable;
uniform sampler2D road_lines : filter_nearest, repeat_disable;
// The lines image of the roads around the lap, and its dashed patterns' (dash, gap).
uniform sampler2D roads_lines : filter_linear, repeat_disable;
uniform vec2 road_dashes[4];
uniform float road_line_width_m = 0.15;
// One row of texels per parking lot.
uniform sampler2D lots : filter_nearest, repeat_disable;
uniform float lap_length_m = 1.0;
// The layer the road's asphalt is drawn with, between its edges.
uniform int road_layer = 0;

// The layer steep faces are drawn with: a photo taken from above shows next to nothing of them.
uniform int slope_layer = 0;

varying vec3 world_position;
varying vec3 world_normal;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

// The step in `uv` that raises `metres`, a quantity varying over the surface, by one metre.
vec2 uv_step_per_m(float metres, vec2 uv) {
	mat2 uv_per_pixel = mat2(dFdx(uv), dFdy(uv));
	vec2 metres_per_pixel = vec2(dFdx(metres), dFdy(metres));
	vec2 metres_per_uv = metres_per_pixel * inverse(uv_per_pixel);
	return metres_per_uv / max(dot(metres_per_uv, metres_per_uv), 1e-6);
}

// A road map's texel as (metres along the road, metres right of its centreline, 1 on a road).
vec3 road_texel(sampler2D map, ivec2 at) {
	vec4 texel = texelFetch(map, at, 0) * 255.0;
	float high = floor(texel.b / 16.0 + 0.001);
	float right_steps = (texel.b - high * 16.0) * 256.0 + texel.a;
	return vec3(
		(texel.r * 4096.0 + texel.g * 16.0 + high) * ALONG_UNIT_M,
		(right_steps - RIGHT_ZERO) * RIGHT_UNIT_M,
		step(right_steps, OFF_ROAD - 0.5));
}

// How far along a road of `map` and right of its centreline `uv` is; false away from any.
// Distances along wrap every `wrap_m`. At a `seam` two roads, or two stretches of one, meet.
bool road_coordinates(
		sampler2D map, vec2 uv, float wrap_m, out float along_m, out float right_m, out bool seam) {
	ivec2 size = textureSize(map, 0);
	vec2 at = uv * vec2(size) - 0.5;
	// By the map's border the coordinates carry on as its last two texels have them: the
	// next tile's map starts there, and a road does not stop at a tile's edge.
	ivec2 corner = clamp(ivec2(floor(at)), ivec2(0), max(size - 2, ivec2(0)));
	vec2 within = at - vec2(corner);
	float first_along_m = 0.0;
	seam = false;
	along_m = 0.0;
	right_m = 0.0;
	for (int index = 0; index < 4; index++) {
		ivec2 offset = ivec2(index & 1, index >> 1);
		vec3 texel = road_texel(map, min(corner + offset, size - 1));
		if (texel.z < 0.5) {
			along_m = 0.0;
			right_m = 0.0;
			return false;
		}
		if (index == 0) {
			first_along_m = texel.x;
		}
		// Across the start line the lap's distance wraps.
		texel.x += wrap_m * round((first_along_m - texel.x) / wrap_m);
		seam = seam || abs(texel.x - first_along_m) > SEAM_M;
		vec2 share = mix(1.0 - within, within, vec2(offset));
		along_m += share.x * share.y * texel.x;
		right_m += share.x * share.y * texel.y;
	}
	if (seam) {
		// Two roads, or two stretches of one, meet here: the nearest texel's stands.
		vec3 texel = road_texel(map, clamp(ivec2(floor(at + 0.5)), ivec2(0), size - 1));
		along_m = texel.x;
		right_m = texel.y;
	}
	along_m = mod(along_m, wrap_m);
	return true;
}

// The two 16-bit numbers a lines image's texel holds: (R, G) and (B, A).
vec2 sixteen_bits(vec4 texel) {
	vec4 bytes = floor(texel * 255.0 + 0.5);
	return vec2(bytes.r * 256.0 + bytes.g, bytes.b * 256.0 + bytes.a);
}

// How much of a road's line covers a fragment `right_m` of the centreline, `along_m` along.
// `offset_m` is the line's, right of the centreline, and `pattern` as the lines image holds it.
float painted_line(
		float offset_m, float pattern, float right_m, float along_m, float soft_m, float along_soft_m) {
	int dashes = int(pattern * 255.0 + 0.5);
	if (dashes == 0) {
		return 0.0;
	}
	float off_m = right_m - offset_m;
	if (dashes == DOUBLE_LINE) {
		off_m = abs(off_m) - road_line_width_m;
	}
	float cover = line_cover(off_m, 0.5 * road_line_width_m, soft_m);
	if (dashes < DOUBLE_LINE) {
		vec2 dash = road_dashes[dashes - 1];
		float phase_m = mod(along_m, dash.x + dash.y);
		cover *= line_cover(phase_m - 0.5 * dash.x, 0.5 * dash.x, along_soft_m);
	}
	return cover;
}

// The joints of slabs `size_m` wide, on ground at `at` metres in the slabs' frame.
float slab_joints(vec2 at, float size_m, float soft_m) {
	vec2 off_m = (fract(at / size_m + 0.5) - 0.5) * size_m;
	float soft = max(soft_m, JOINT_WIDTH_M);
	return max(line_cover(off_m.x, 0.5 * JOINT_WIDTH_M, soft), line_cover(off_m.y, 0.5 * JOINT_WIDTH_M, soft))
		* JOINT_WIDTH_M / soft;
}

void fragment() {
	vec2 world_xz = world_position.xz;
	float distance_m = length(world_position - CAMERA_POSITION_WORLD);
	float near = 1.0 - smoothstep(40.0, 160.0, distance_m);
	vec2 wobble = vec2(value_noise(world_xz * 2.3), value_noise(world_xz * 2.3 + 17.0)) - 0.5;
	vec2 map_uv = UV + near * wobble * BORDER_WOBBLE_PX / vec2(textureSize(surface_map, 0));
	float weights[10];
	layer_weights(map_uv, mix(1.0, BORDER_SHARPNESS, near), weights);
	vec3 photo_colour = photo_albedo(UV);
	vec3 soft_photo_colour = photo_albedo_soft(UV);

	float along_m;
	float right_m;
	bool lap_seam;
	bool by_the_road = road_coordinates(track_map, UV, lap_length_m, along_m, right_m, lap_seam);
	float road_along_m;
	float road_right_m;
	bool road_seam;
	bool by_a_road = road_coordinates(
		roads_map, UV, NO_WRAP_M, road_along_m, road_right_m, road_seam);
	// Everything read from screen-space gradients is read here, for every fragment: inside a
	// branch the gradients are undefined along the branch's border and leave a dotted line.
	vec2 uv_across = dFdx(UV);
	vec2 uv_down = dFdy(UV);
	vec2 uv_per_m_right = uv_step_per_m(right_m, UV);
	// Where the track map ends the coordinates jump: the softening stays that of a surface.
	float soft_m = clamp(fwidth(right_m), 0.004, MAX_SOFT_M);
	float wave_soft = clamp(PI * fwidth(along_m) / KERB_STRIPE_M, 0.01, 1.0);
	float road_soft_m = clamp(fwidth(road_right_m), 0.004, MAX_SOFT_M);
	float road_along_soft_m = clamp(fwidth(road_along_m), 0.004, 1.0);
	float ground_soft_m = clamp(length(fwidth(world_xz)), 0.004, MAX_SOFT_M);
	float marking = 0.0;
	float joints = 0.0;

	// A road around the lap is its fitted model: its layer and colour between its edges,
	// whatever the photo's pixels show there, and the markings painted on it.
	if (by_a_road) {
		vec2 size = vec2(textureSize(roads_lines, 0));
		float band = floor(road_along_m / size.x);
		float column = road_along_m - band * size.x;
		float first_row = band * ROAD_ROWS;
		float u = (column + 0.5) / size.x;
		ivec2 metre = ivec2(int(column + 0.5), int(first_row));
		// Widths and offsets are 16 bits a metre: blended here between the road's two metres.
		int low = clamp(int(floor(column)), 0, int(size.x) - 1);
		int high = min(low + 1, int(size.x) - 1);
		float share = clamp(column - float(low), 0.0, 1.0);
		float half_width_m = mix(
			sixteen_bits(texelFetch(roads_lines, ivec2(low, metre.y), 0)).x,
			sixteen_bits(texelFetch(roads_lines, ivec2(high, metre.y), 0)).x, share) * EDGE_UNIT_M;
		int layer = int(texelFetch(roads_lines, metre, 0).b * 255.0 + 0.5);
		float on_a_road = 1.0
			- smoothstep(half_width_m - road_soft_m, half_width_m + road_soft_m, abs(road_right_m));
		float lane = (road_right_m / max(half_width_m, 0.1) * 0.5 + 0.5) * ROAD_COLOUR_LANES;
		float colour_row = first_row + 2.0 + float(ROAD_LINES)
			+ clamp(lane, 0.5, ROAD_COLOUR_LANES - 0.5);
		vec3 road_colour = linear_light(
			textureLod(roads_lines, vec2(u, colour_row / size.y), 0.0).rgb);
		photo_colour = mix(photo_colour, road_colour, on_a_road);
		soft_photo_colour = mix(soft_photo_colour, road_colour, on_a_road);
		for (int index = 0; index < LAYER_COUNT; index++) {
			weights[index] = mix(weights[index], index == layer ? 1.0 : 0.0, on_a_road);
		}
		for (int line = 0; line < ROAD_LINES; line++) {
			int row = metre.y + 2 + line;
			float offset_m = (mix(
				sixteen_bits(texelFetch(roads_lines, ivec2(low, row), 0)).x,
				sixteen_bits(texelFetch(roads_lines, ivec2(high, row), 0)).x, share) - OFFSET_ZERO)
				* EDGE_UNIT_M;
			float pattern = texelFetch(roads_lines, ivec2(metre.x, row), 0).b;
			marking = max(marking, painted_line(offset_m, pattern, road_right_m, road_along_m,
				road_soft_m, road_along_soft_m));
		}
		vec4 across = texelFetch(roads_lines, ivec2(int(column), int(first_row) + 1), 0) * 255.0;
		int kind = int(across.r + 0.5);
		vec2 ends_m = (across.gb - 128.0) * ENDS_UNIT_M;
		float between = smoothstep(ends_m.x - road_soft_m, ends_m.x + road_soft_m, road_right_m)
			* (1.0 - smoothstep(ends_m.y - road_soft_m, ends_m.y + road_soft_m, road_right_m));
		if (kind == STOP_LINE) {
			marking = max(marking, between
				* line_cover(fract(column) - 0.5, 0.5 * STOP_LINE_WIDTH_M, road_along_soft_m));
		}
		if (kind == GIVE_WAY_LINE || kind == GIVE_WAY_LINE_AGAINST) {
			float towards_tip = (fract(column) - 0.5) * (kind == GIVE_WAY_LINE ? -1.0 : 1.0);
			float narrowing = clamp(0.5 - towards_tip / GIVE_WAY_HEIGHT_M, 0.0, 1.0);
			float tooth_m = (fract(road_right_m / GIVE_WAY_PITCH_M) - 0.5) * GIVE_WAY_PITCH_M;
			marking = max(marking, between
				* line_cover(tooth_m, 0.5 * GIVE_WAY_BASE_M * narrowing, road_soft_m)
				* line_cover(towards_tip, 0.5 * GIVE_WAY_HEIGHT_M, road_along_soft_m));
		}
		if (kind == CROSSING) {
			float stripe_m = (fract(0.5 * road_right_m / CROSSING_STRIPE_M) - 0.5)
				* 2.0 * CROSSING_STRIPE_M;
			marking = max(marking, between * line_cover(stripe_m, 0.5 * CROSSING_STRIPE_M, road_soft_m));
		}
		// At a seam the coordinates are one texel's: paint drawn from them is a staircase.
		marking *= on_a_road * (road_seam ? 0.0 : 1.0);
		if (layer_joints_m[layer] > 0.0) {
			joints = on_a_road * slab_joints(vec2(road_right_m, road_along_m),
				layer_joints_m[layer], max(road_soft_m, road_along_soft_m));
		}
	}

	// A parking lot is drawn empty: its layer and its colour without the cars, to its fitted
	// edge, and the bays of its fitted grid.
	ivec2 lots_size = textureSize(lots_map, 0);
	vec2 lot_at = UV * vec2(lots_size) - 0.5;
	ivec2 lot_corner = ivec2(floor(lot_at));
	vec2 lot_within = fract(lot_at);
	int lot = int(texelFetch(lots_map, clamp(ivec2(floor(lot_at + 0.5)), ivec2(0), lots_size - 1), 0).r
		* 255.0 + 0.5);
	if (lot > 0) {
		float edge_m = 0.0;
		for (int index = 0; index < 4; index++) {
			ivec2 offset = ivec2(index & 1, index >> 1);
			vec4 texel = texelFetch(lots_map, clamp(lot_corner + offset, ivec2(0), lots_size - 1), 0);
			vec2 share = mix(1.0 - lot_within, lot_within, vec2(offset));
			edge_m += share.x * share.y * (int(texel.r * 255.0 + 0.5) == lot
				? (texel.g * 255.0 - LOT_EDGE_ZERO) * LOT_EDGE_UNIT_M : LOT_OUTSIDE_M);
		}
		float in_lot = 1.0 - smoothstep(-ground_soft_m, ground_soft_m, edge_m);
		vec4 frame = texelFetch(lots, ivec2(0, lot - 1), 0);
		vec4 surface = texelFetch(lots, ivec2(1, lot - 1), 0);
		vec4 bays = texelFetch(lots, ivec2(2, lot - 1), 0);
		vec2 in_frame = vec2(dot(world_xz - frame.xy, frame.zw),
			dot(world_xz - frame.xy, vec2(frame.w, -frame.z)));
		int layer = int(surface.a + 0.5);
		float patches = value_noise(world_xz * 0.07) * 0.6 + value_noise(world_xz * 0.31) * 0.4;
		vec3 lot_colour = surface.rgb * (1.0 + LOT_VARIATION * (patches - 0.5));
		photo_colour = mix(photo_colour, lot_colour, in_lot);
		soft_photo_colour = mix(soft_photo_colour, lot_colour, in_lot);
		for (int index = 0; index < LAYER_COUNT; index++) {
			weights[index] = mix(weights[index], index == layer ? 1.0 : 0.0, in_lot);
		}
		float bay_lines = 0.0;
		float half_line_m = 0.5 * BAY_LINE_WIDTH_M;
		int rows = int(bays.g + 0.5);
		for (int row = 0; row < MAX_LOT_ROWS; row++) {
			if (row >= rows) {
				break;
			}
			vec4 reach = texelFetch(lots, ivec2(LOT_HEADER_TEXELS + 2 * row, lot - 1), 0);
			vec4 closed = texelFetch(lots, ivec2(LOT_HEADER_TEXELS + 2 * row + 1, lot - 1), 0);
			float divider_m = (fract((in_frame.x - reach.x) / bays.r + 0.5) - 0.5) * bays.r;
			float along_row = step(reach.x - half_line_m, in_frame.x)
				* step(in_frame.x, reach.y + half_line_m);
			float across_row = step(reach.z, in_frame.y) * step(in_frame.y, reach.w);
			bay_lines = max(bay_lines,
				along_row * across_row * line_cover(divider_m, half_line_m, ground_soft_m));
			float closing = max(closed.r * line_cover(in_frame.y - reach.z, half_line_m, ground_soft_m),
				closed.g * line_cover(in_frame.y - reach.w, half_line_m, ground_soft_m));
			bay_lines = max(bay_lines, along_row * closing);
		}
		marking = mix(marking, bay_lines, in_lot);
		joints *= 1.0 - in_lot;
		if (layer_joints_m[layer] > 0.0) {
			joints = max(joints, in_lot * slab_joints(in_frame, layer_joints_m[layer], ground_soft_m));
		}
	}
	float edge_m = 0.0;
	float kerb_m = 0.0;
	float line_m = 0.0;
	float rubbered = 0.0;
	float line_painted = 0.0;
	float on_road = 0.0;
	float from_centre_m = abs(right_m);
	if (by_the_road) {
		// The lines image holds a value per metre: blended here between the lap's two metres.
		int last = textureSize(road_lines, 0).x - 1;
		int low = clamp(int(floor(along_m)), 0, last);
		int high = min(low + 1, last);
		float share = clamp(along_m - float(low), 0.0, 1.0);
		vec2 edges = mix(
			sixteen_bits(texelFetch(road_lines, ivec2(low, 0), 0)),
			sixteen_bits(texelFetch(road_lines, ivec2(high, 0), 0)), share) * EDGE_UNIT_M;
		vec4 kerbs = mix(
			texelFetch(road_lines, ivec2(low, 1), 0), texelFetch(road_lines, ivec2(high, 1), 0), share);
		vec4 painted = mix(
			texelFetch(road_lines, ivec2(low, 2), 0), texelFetch(road_lines, ivec2(high, 2), 0), share);
		edge_m = right_m < 0.0 ? edges.x : edges.y;
		kerb_m = (right_m < 0.0 ? kerbs.r : kerbs.g) * 255.0 * KERB_UNIT_M;
		line_painted = right_m < 0.0 ? painted.r : painted.g;
		line_m = (kerbs.b * 255.0 - 128.0) * RACING_LINE_UNIT_M;
		rubbered = kerbs.a;
		// Between its edges the road is its asphalt, whatever the photo's pixels say there.
		on_road = 1.0 - smoothstep(edge_m - soft_m, edge_m + soft_m, from_centre_m);
		for (int layer = 0; layer < LAYER_COUNT; layer++) {
			weights[layer] = mix(weights[layer], layer == road_layer ? 1.0 : 0.0, on_road);
		}
		// By its edge the road takes the photo's colour from further in, clear of the photo's
		// own blurred edge line, kerb and verge.
		float beyond_m = max(from_centre_m - (edge_m - PHOTO_CLEAR_OF_EDGE_M), 0.0);
		vec2 inward = -sign(right_m) * uv_per_m_right * beyond_m;
		vec3 further_in = graded(textureGrad(photo, UV + inward, uv_across, uv_down).rgb);
		float by_edge = step(from_centre_m, edge_m + kerb_m + 0.3);
		photo_colour = mix(photo_colour, further_in, on_road * by_edge);
		// Asphalt is grey: what colour the photo shows on it is fringing, but for paint.
		float photo_grey = dot(photo_colour, vec3(0.2126, 0.7152, 0.0722));
		float painted_colour = smoothstep(0.25, 0.5, length(photo_colour - photo_grey) / max(photo_grey, 1e-3));
		photo_colour = mix(photo_colour, vec3(photo_grey), on_road * (1.0 - painted_colour) * ROAD_GREYING);
	}

	// A steep face keeps the photo's colour over a few metres only, takes the slope's layer,
	// and reads the layers' textures on a vertical plane, where they do not stretch.
	vec3 facing = normalize(world_normal);
	float steep = (1.0 - smoothstep(STEEP_AT, STEEP_FROM, facing.y)) * (1.0 - on_road);
	if (steep > 0.0) {
		vec3 blurred = photo_albedo_blurred(UV);
		photo_colour = mix(photo_colour, blurred, steep);
		soft_photo_colour = mix(soft_photo_colour, blurred, steep);
		for (int layer = 0; layer < LAYER_COUNT; layer++) {
			weights[layer] = mix(weights[layer], layer == slope_layer ? 1.0 : 0.0, steep);
		}
	}
	vec2 detail_at = world_xz;
	if (facing.y < STEEP_AT) {
		detail_at = abs(facing.x) > abs(facing.z) ? world_position.zy : world_position.xy;
	}
	Ground ground = ground_layers(weights, photo_colour, soft_photo_colour, detail_at, distance_m);
	vec3 albedo = ground.albedo;
	float roughness = ground.roughness;
	// Paint is worn: it lets the ground show through in patches, and is no smoother than it.
	float wear = 0.75 + 0.25 * value_noise(world_xz * 9.0) * value_noise(world_xz * 1.7);
	marking *= (1.0 - on_road) * (0.72 + 0.28 * smoothstep(0.2, 0.6, value_noise(world_xz * 3.1)));
	albedo *= 1.0 - 0.5 * joints * (1.0 - on_road) * (1.0 - smoothstep(40.0, 120.0, distance_m));
	albedo = mix(albedo, LINE_WHITE * wear, marking * 0.92);
	float paint = marking;
	if (by_the_road) {
		float streaks = value_noise(vec2(right_m * 2.3, along_m * 0.045))
			* value_noise(vec2(right_m * 7.1 + 3.0, along_m * 0.11));
		float off_line = (right_m - line_m) / RUBBER_HALF_WIDTH_M;
		float rubber = rubbered * exp(-off_line * off_line) * (0.45 + 1.1 * streaks);
		rubber *= 1.0 - smoothstep(edge_m - 0.3, edge_m, from_centre_m);
		rubber = clamp(rubber, 0.0, 1.0);
		albedo *= 1.0 - 0.45 * rubber;
		roughness -= 0.12 * rubber;

		// The edge line keeps one inset from the asphalt's edge, kerb or verge beyond it.
		float line_outer_m = edge_m - LINE_INSET_M;
		float line = smoothstep(
				line_outer_m - LINE_WIDTH_M - soft_m, line_outer_m - LINE_WIDTH_M, from_centre_m)
			* (1.0 - smoothstep(line_outer_m, line_outer_m + soft_m, from_centre_m));
		albedo = mix(albedo, LINE_WHITE * wear, line * 0.92 * step(0.5, line_painted));

		float kerb = step(0.05, kerb_m) * smoothstep(edge_m - soft_m, edge_m, from_centre_m)
			* (1.0 - smoothstep(edge_m + kerb_m, edge_m + kerb_m + soft_m, from_centre_m));
		// Red and white alternate every stripe; far away they merge into their mean.
		float wave = sin(PI * along_m / KERB_STRIPE_M);
		float stripe = smoothstep(-wave_soft, wave_soft, wave);
		vec3 kerb_colour = mix(KERB_RED, KERB_WHITE, stripe);
		float grime = 0.7 + 0.3 * value_noise(world_xz * 5.0) - 0.25 * value_noise(world_xz * 0.9);
		albedo = mix(albedo, kerb_colour * grime, kerb);
		paint = max(paint, max(line * step(0.5, line_painted), kerb));
	}

	ALBEDO = albedo;
	ROUGHNESS = mix(roughness, PAINT_ROUGHNESS, paint);
	SPECULAR = 0.35;
	vec3 tangent_normal = normalize(mix(ground.normal, vec3(0.0, 0.0, 1.0), 0.4 * paint));
	NORMAL = ground_view_normal(NORMAL, tangent_normal, VIEW_MATRIX, INV_VIEW_MATRIX);
}
