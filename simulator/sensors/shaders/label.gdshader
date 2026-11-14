// The label pass: drawn after a surface's own material, over it, for the ground truth camera
// only (the camera whose cull mask lacks the label layer). It shows the surface's class and
// the mark of a labelled pixel; for every other camera its triangles are empty.
// It writes its depth: a label only tested against depth now and then lost a 2x2 quad on
// RADV (RX 7800 XT), which showed unlabelled.
shader_type spatial;
render_mode unshaded, fog_disabled, cull_disabled, depth_draw_always, skip_vertex_transform;

#include "label.gdshaderinc"

// How much nearer than its surface a label is drawn, as a share of the distance: the two are
// drawn by different programs, whose depths may differ in their last bits.
const float NEARER = 5e-5;

uniform float class_id = 0.0;

void vertex() {
	if ((CAMERA_VISIBLE_LAYERS & LABEL_LAYER) == 0u) {
		// As the renderer transforms a vertex, then along its ray towards the camera, where it
		// is seen at the same place, so its depth passes the test against its surface's.
		VERTEX = (MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz * (1.0 - NEARER);
	} else {
		VERTEX = vec3(0.0);
	}
}

void fragment() {
	ALBEDO = vec3(class_id * LABEL_STEP, LABELLED, 0.0);
}
