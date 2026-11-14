// The lenses of a three-aspect traffic signal, lit in turn on a fixed cycle: green, amber,
// red. COLOR is a lens's colour, UV2.x its aspect (0 green, 1 amber, 2 red) and
// INSTANCE_CUSTOM.r the head's place in the cycle, 0 to 1.
shader_type spatial;

uniform float green_s = 18.0;
uniform float amber_s = 3.0;
uniform float red_s = 23.0;

const float LIT_ENERGY = 1.6;
const float UNLIT = 0.06;

varying float cycle_phase;

void vertex() {
	cycle_phase = INSTANCE_CUSTOM.r;
}

void fragment() {
	float cycle_s = green_s + amber_s + red_s;
	float elapsed_s = fract(TIME / cycle_s + cycle_phase) * cycle_s;
	float showing = step(green_s, elapsed_s) + step(green_s + amber_s, elapsed_s);
	float lit = 1.0 - step(0.5, abs(showing - UV2.x));
	ALBEDO = COLOR.rgb * mix(UNLIT, 1.0, lit);
	EMISSION = COLOR.rgb * LIT_ENERGY * lit;
	ROUGHNESS = 0.25;
}
