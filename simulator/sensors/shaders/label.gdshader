// The label pass: drawn after a surface's own material, over it, for the ground truth camera
// only (the camera whose cull mask lacks the label layer). It shows the surface's class and
// the mark of a labelled pixel; for every other camera its triangles are empty.
shader_type spatial;
render_mode unshaded, fog_disabled, cull_disabled;

#include "label.gdshaderinc"

uniform float class_id = 0.0;

void vertex() {
	if ((CAMERA_VISIBLE_LAYERS & LABEL_LAYER) != 0u) {
		VERTEX = vec3(0.0);
	}
}

void fragment() {
	ALBEDO = vec3(class_id * LABEL_STEP, LABELLED, 0.0);
}
