// A tree impostor: views of a tree around its trunk, side by side in an atlas, on crossed
// cards. The instance colour tints the tree. Towards the end of its draw distance a tree
// shrinks to its foot, into the canopy that stands for it from there on.
shader_type spatial;
render_mode cull_disabled, depth_draw_opaque;

#include "res://sensors/shaders/label.gdshaderinc"

uniform sampler2D atlas : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform float fades_from_m = 1e9;
uniform float gone_at_m = 2e9;

varying vec3 tint;

void vertex() {
	tint = COLOR.rgb;
	vec3 foot = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	VERTEX *= 1.0 - smoothstep(fades_from_m, gone_at_m, distance(foot, CAMERA_POSITION_WORLD));
}

void fragment() {
	vec4 colour = texture(atlas, UV);
	ALBEDO = colour.rgb * tint;
	ALPHA = colour.a;
	ALPHA_SCISSOR_THRESHOLD = 0.45;
	ALPHA_ANTIALIASING_EDGE = 0.3;
	ALPHA_TEXTURE_COORDINATE = UV * vec2(textureSize(atlas, 0));
	ROUGHNESS = 1.0;
	// No sky reflection: Godot looks the sky's radiance up with implicit derivatives, which are
	// undefined beside a pixel the alpha scissor discards, so the edges would flicker.
	SPECULAR = 0.0;
	// Cards lit as a crown is: from above, and with the light that passes through the leaves.
	NORMAL = normalize(mix(NORMAL, (VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz, 0.55));
	BACKLIGHT = vec3(0.25, 0.3, 0.2);
	LABEL_AS(CLASS_VEGETATION)
	// A label is whole or absent: a soft edge would blend two classes into a third.
	if ((CAMERA_VISIBLE_LAYERS & LABEL_LAYER) == 0u) {
		ALPHA = step(0.45, colour.a);
	}
}
