// The canopy: the woods as one surface over the crowns. Its vertices carry the crowns'
// colour; the orthophoto under UV2 makes it lighter and darker as the woods are from above,
// crown by crown, and round crowns with shaded gaps between them are drawn on it. Near the
// camera it lies under the ground; it rises to the crowns over the distance before the trees
// fade out. UV.x is how far a vertex stands above the canopy's hem.
shader_type spatial;
render_mode cull_disabled;

#include "res://sensors/shaders/label.gdshaderinc"

const float CROWN_M = 5.0;
const float GAP_SHADE = 0.18;
const float ROUNDNESS = 1.6;
// Crowns seen from afar are darker than their leaves: they shade themselves.
const vec3 SELF_SHADE = vec3(0.55, 0.78, 0.55);
const float UNDER_CROWNS_M = 9.0;
const float TRUNK_SHADE = 0.35;
// The photo's mipmap that shows a stand of trees, not its crowns.
const float STAND_LOD = 4.0;
const vec2 PHOTO_RANGE = vec2(0.45, 1.7);

uniform sampler2D photo : source_color, filter_linear_mipmap, repeat_disable;
uniform vec3 photo_black;
uniform float photo_gamma = 1.0;
uniform float rises_from_m = 0.0;
uniform float risen_at_m = 0.0;

varying vec3 stood;
varying float wall;

float brightness(vec3 colour) {
	// The terrain surface's grade: the photo's haze removed, its contrast undone.
	vec3 graded = pow(max(colour - photo_black, vec3(0.0)), vec3(photo_gamma));
	return dot(graded, vec3(0.2126, 0.7152, 0.0722));
}

vec2 crown_centre(vec2 cell) {
	return cell + fract(sin(vec2(dot(cell, vec2(127.1, 311.7)), dot(cell, vec2(269.5, 183.3)))) * 43758.5453);
}

void vertex() {
	stood = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wall = NORMAL.y < 0.1 ? 1.0 : 0.0;
	float risen = smoothstep(rises_from_m, risen_at_m, distance(stood, CAMERA_POSITION_WORLD));
	VERTEX.y -= UV.x * (1.0 - risen);
}

void fragment() {
	// The photo is read before any branch: its gradients are undefined inside one.
	float crown_light = brightness(texture(photo, UV2).rgb);
	float stand_light = brightness(textureLod(photo, UV2, STAND_LOD).rgb);
	// A wall of the canopy shows crowns one above the other.
	vec2 at = (stood.xz + wall * stood.y * vec2(0.83, 0.55)) / CROWN_M;
	vec2 to_crown = vec2(8.0);
	for (int row = -1; row <= 1; row++) {
		for (int column = -1; column <= 1; column++) {
			vec2 towards = crown_centre(floor(at) + vec2(float(column), float(row))) - at;
			if (dot(towards, towards) < dot(to_crown, to_crown)) {
				to_crown = towards;
			}
		}
	}
	float lit = mix(GAP_SHADE, 1.0, 1.0 - smoothstep(0.3, 0.6, length(to_crown)));
	float from_above = clamp(crown_light / max(stand_light, 1e-4), PHOTO_RANGE.x, PHOTO_RANGE.y);
	float under_crowns = mix(TRUNK_SHADE, 1.0, smoothstep(0.0, UNDER_CROWNS_M, UV.x));
	ALBEDO = COLOR.rgb * SELF_SHADE * under_crowns * lit * mix(from_above, 1.0, wall);
	ROUGHNESS = 1.0;
	SPECULAR = 0.1;
	// Each crown is round: lit on its sunny side, as the trees' cards are from above.
	vec3 round_crown = normalize(vec3(-to_crown.x * ROUNDNESS, 1.0, -to_crown.y * ROUNDNESS));
	NORMAL = normalize(mix(NORMAL, (VIEW_MATRIX * vec4(round_crown, 0.0)).xyz, 0.75));
	BACKLIGHT = vec3(0.25, 0.3, 0.2);
	LABEL_AS(CLASS_VEGETATION)
}
