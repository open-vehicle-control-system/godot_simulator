// The ground of a track: up to ten tiled layers chosen per pixel by a surface map, coloured
// by the orthophoto. Near the camera the layers give the detail and the photo their tint;
// far away the photo alone remains.

const int LAYER_COUNT = 10;
const float COARSE_SCALE = 5.3;
const float COARSE_TURN_RAD = 0.61;
const float SHARP_PHOTO_FROM = 0.95;
const float SOFT_PHOTO_LOD = 2.0;

uniform sampler2D photo : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform sampler2D surface_map : filter_nearest, repeat_disable;
uniform sampler2DArray layer_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2DArray layer_normal : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2DArray layer_roughness : filter_linear_mipmap_anisotropic, repeat_enable;
uniform float layer_size_m[10];
uniform vec3 layer_mean[10];
// How far each layer takes the photo's colour: 0 keeps its own, 1 is the photo's.
uniform float layer_photo[10];
// The power a layer's grain is raised to, so that every layer shows as much of it.
uniform float layer_grain[10];
// The size of the slabs a layer is laid in; 0 for a layer without joints.
uniform float layer_joints_m[10];
uniform vec3 photo_black;
uniform vec3 photo_gain = vec3(1.0);
uniform float photo_gamma = 1.0;
uniform float photo_saturation = 1.0;

struct Ground {
	vec3 albedo;
	vec3 normal; // tangent space: x along world +X, y along world +Z
	float roughness;
};

const float BLURRED_PHOTO_LOD = 4.0;
const float BRIGHTEST_ALBEDO = 0.55;

// Light the photo recorded as albedo: its haze removed, its contrast and exposure undone.
vec3 graded(vec3 photo_light) {
	vec3 light = max(photo_light - photo_black, vec3(0.0));
	vec3 albedo = photo_gain * pow(light, vec3(photo_gamma));
	float grey = dot(albedo, vec3(0.2126, 0.7152, 0.0722));
	return clamp(mix(vec3(grey), albedo, photo_saturation), vec3(0.0), vec3(BRIGHTEST_ALBEDO));
}

// An sRGB colour stored as data, in linear light.
vec3 linear_light(vec3 srgb) {
	return mix(srgb / 12.92, pow((srgb + 0.055) / 1.055, vec3(2.4)), step(0.04045, srgb));
}

// How much of a line `half_width_m` to each side of where `off_m` is 0 covers a fragment
// `soft_m` wide.
float line_cover(float off_m, float half_width_m, float soft_m) {
	return 1.0 - smoothstep(half_width_m - 0.5 * soft_m, half_width_m + 0.5 * soft_m, abs(off_m));
}

// A normal map's texel: it stores x and y, z is what makes the normal a unit long.
vec3 stored_normal(vec2 stored) {
	vec2 across = stored * 2.0 - 1.0;
	return vec3(stored, 0.5 + 0.5 * sqrt(max(1.0 - dot(across, across), 0.0)));
}

vec3 photo_albedo(vec2 uv) {
	return graded(texture(photo, uv).rgb);
}

vec3 photo_albedo_soft(vec2 uv) {
	return graded(textureLod(photo, uv, max(SOFT_PHOTO_LOD, textureQueryLod(photo, uv).y)).rgb);
}

// The photo's colour over a few metres around `uv`.
vec3 photo_albedo_blurred(vec2 uv) {
	return graded(textureLod(photo, uv, BLURRED_PHOTO_LOD).rgb);
}

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

// The weight of each layer at `uv`: the surface map's layers around it, blended over one
// pixel and sharpened by `sharpness` so borders stay crisp.
void layer_weights(vec2 uv, float sharpness, out float weights[10]) {
	for (int layer = 0; layer < LAYER_COUNT; layer++) {
		weights[layer] = 0.0;
	}
	ivec2 size = textureSize(surface_map, 0);
	vec2 at = uv * vec2(size) - 0.5;
	ivec2 corner = ivec2(floor(at));
	vec2 within = fract(at);
	for (int index = 0; index < 4; index++) {
		ivec2 offset = ivec2(index & 1, index >> 1);
		ivec2 texel = clamp(corner + offset, ivec2(0), size - 1);
		int layer = clamp(int(texelFetch(surface_map, texel, 0).r * 255.0 + 0.5), 0, LAYER_COUNT - 1);
		vec2 share = mix(1.0 - within, within, vec2(offset));
		weights[layer] += share.x * share.y;
	}
	float total = 0.0;
	for (int layer = 0; layer < LAYER_COUNT; layer++) {
		weights[layer] = pow(weights[layer], sharpness);
		total += weights[layer];
	}
	for (int layer = 0; layer < LAYER_COUNT; layer++) {
		weights[layer] /= total;
	}
}

// The ground's colour, normal and roughness. `detail_at` is where the layers' textures are
// read, in metres: the world's (x, z) on flat ground, a vertical plane on a steep face.
Ground ground_layers(
		float weights[10], vec3 photo_colour, vec3 soft_photo_colour, vec2 detail_at, float distance_m) {
	Ground ground;
	ground.albedo = vec3(0.0);
	ground.normal = vec3(0.0);
	ground.roughness = 0.0;
	vec2 across = dFdx(detail_at);
	vec2 down = dFdy(detail_at);
	mat2 turn = mat2(
		vec2(cos(COARSE_TURN_RAD), sin(COARSE_TURN_RAD)),
		vec2(-sin(COARSE_TURN_RAD), cos(COARSE_TURN_RAD)));
	for (int layer = 0; layer < LAYER_COUNT; layer++) {
		float weight = weights[layer];
		if (weight < 0.004) {
			continue;
		}
		float size_m = layer_size_m[layer];
		vec3 mean = layer_mean[layer];
		// Fine detail near, the same texture enlarged and turned further out, its mean beyond.
		float to_coarse = smoothstep(6.0, 30.0, distance_m / size_m);
		float to_mean = smoothstep(60.0, 240.0, distance_m / size_m);
		vec2 fine_uv = detail_at / size_m;
		vec2 coarse_uv = turn * detail_at / (size_m * COARSE_SCALE) + 0.37;
		vec3 coarse = textureGrad(layer_albedo, vec3(coarse_uv, float(layer)),
			turn * across / (size_m * COARSE_SCALE), turn * down / (size_m * COARSE_SCALE)).rgb;
		vec3 albedo = coarse;
		vec3 normal = vec3(0.5, 0.5, 1.0);
		float roughness = 0.9;
		if (to_coarse < 1.0) {
			vec3 fine_at = vec3(fine_uv, float(layer));
			vec3 fine = textureGrad(layer_albedo, fine_at, across / size_m, down / size_m).rgb;
			float variation = dot(coarse, vec3(0.333)) / max(dot(mean, vec3(0.333)), 1e-3);
			albedo = mix(fine * mix(1.0, variation, 0.6), coarse, to_coarse);
			normal = mix(
				stored_normal(textureGrad(layer_normal, fine_at, across / size_m, down / size_m).rg),
				normal, to_coarse);
			roughness = mix(textureGrad(layer_roughness, fine_at, across / size_m, down / size_m).r,
				roughness, to_coarse);
		}
		albedo = mix(albedo, mean, to_mean);
		// The photo's colour carrying the layer's grain, as far as the layer takes the photo.
		float grain = dot(albedo, vec3(0.333)) / max(dot(mean, vec3(0.333)), 1e-3);
		// Vegetation takes the photo's colour over a metre: its pixels are blotches up close.
		vec3 tint = layer_photo[layer] < SHARP_PHOTO_FROM ? soft_photo_colour : photo_colour;
		vec3 photographed = tint * pow(clamp(grain, 0.25, 4.0), layer_grain[layer]);
		albedo = mix(albedo, photographed, layer_photo[layer]);
		ground.albedo += weight * albedo;
		ground.normal += weight * normal;
		ground.roughness += weight * roughness;
	}
	ground.normal = normalize(ground.normal * 2.0 - 1.0);
	return ground;
}

// The view-space normal of a ground whose tangent-space normal is `tangent_normal`.
vec3 ground_view_normal(vec3 view_normal, vec3 tangent_normal, mat4 view, mat4 inverse_view) {
	vec3 up = normalize((inverse_view * vec4(view_normal, 0.0)).xyz);
	vec3 along_x = normalize(vec3(1.0, 0.0, 0.0) - up * up.x);
	vec3 along_z = cross(along_x, up);
	vec3 world = along_x * tangent_normal.x + along_z * tangent_normal.y + up * tangent_normal.z;
	return normalize((view * vec4(normalize(world), 0.0)).xyz);
}
