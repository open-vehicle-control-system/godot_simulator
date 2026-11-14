// A road sign's plate: its face on the front, bare galvanised sheet on the back.
shader_type spatial;
render_mode cull_disabled;

uniform sampler2D face : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform vec3 back_colour : source_color = vec3(0.42, 0.43, 0.44);

const float FACE_ROUGHNESS = 0.45;
const float BACK_ROUGHNESS = 0.55;
const float BACK_METALLIC = 0.6;

void fragment() {
	vec3 shown = texture(face, UV).rgb;
	float front = float(FRONT_FACING);
	ALBEDO = mix(back_colour, shown, front);
	ROUGHNESS = mix(BACK_ROUGHNESS, FACE_ROUGHNESS, front);
	METALLIC = mix(BACK_METALLIC, 0.0, front);
}
