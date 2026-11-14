shader_type spatial;
// The vehicle's mirror glass (mirrors.gd): each mirror shows its own view of what is behind,
// spread over the glass's width and height. Body frame: +X left, +Y up, +Z forward.
render_mode cull_disabled;

uniform sampler2D left_view : filter_linear, repeat_disable;
uniform sampler2D interior_view : filter_linear, repeat_disable;
uniform sampler2D right_view : filter_linear, repeat_disable;
uniform vec3 left_low;
uniform vec3 left_high;
uniform vec3 interior_low;
uniform vec3 interior_high;
uniform vec3 right_low;
uniform vec3 right_high;
// Glass further than this from the centreline is a door mirror's.
uniform float door_mirrors_beyond_m;
// Silvered glass returns a little less light than it receives.
uniform float reflectance = 0.9;
// False while the views are not rendered: the glass is then plain polished metal.
uniform bool live = false;

varying vec3 on_body;

void vertex() {
	on_body = VERTEX;
}

vec2 across_glass(vec3 point, vec3 low, vec3 high) {
	vec2 size = max(high.xy - low.xy, vec2(0.001));
	return vec2((point.x - low.x) / size.x, 1.0 - (point.y - low.y) / size.y);
}

void fragment() {
	// A view looking back has the vehicle's left on its right, as a mirror shows it.
	vec3 view;
	if (on_body.x > door_mirrors_beyond_m) {
		view = textureLod(left_view, across_glass(on_body, left_low, left_high), 0.0).rgb;
	} else if (on_body.x < -door_mirrors_beyond_m) {
		view = textureLod(right_view, across_glass(on_body, right_low, right_high), 0.0).rgb;
	} else {
		view = textureLod(interior_view, across_glass(on_body, interior_low, interior_high), 0.0).rgb;
	}
	if (live) {
		ALBEDO = vec3(0.0);
		SPECULAR = 0.0;
		ROUGHNESS = 1.0;
		EMISSION = view * reflectance;
	} else {
		ALBEDO = vec3(reflectance);
		METALLIC = 1.0;
		ROUGHNESS = 0.05;
	}
}
