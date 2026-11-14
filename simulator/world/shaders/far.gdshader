// The far terrain: the ground beyond the loaded tiles, as the orthophoto alone shows it.
shader_type spatial;
render_mode cull_disabled;

#include "res://sensors/shaders/label.gdshaderinc"

const float BRIGHTEST_ALBEDO = 0.55;

uniform sampler2D photo : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform vec3 photo_black;
uniform vec3 photo_gain = vec3(1.0);
uniform float photo_gamma = 1.0;
uniform float photo_saturation = 1.0;

void fragment() {
	// The terrain surface's grade: the photo's haze removed, its contrast and exposure undone.
	vec3 light = max(texture(photo, UV).rgb - photo_black, vec3(0.0));
	vec3 albedo = photo_gain * pow(light, vec3(photo_gamma));
	float grey = dot(albedo, vec3(0.2126, 0.7152, 0.0722));
	ALBEDO = clamp(mix(vec3(grey), albedo, photo_saturation), vec3(0.0), vec3(BRIGHTEST_ALBEDO));
	ROUGHNESS = 0.9;
	SPECULAR = 0.35;
	LABEL_AS(CLASS_TERRAIN)
}
