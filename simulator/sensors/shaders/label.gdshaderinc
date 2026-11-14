// What a surface is, drawn for the ground truth camera in place of its colour: the camera
// whose cull mask lacks the label layer. A label is the class times the mark's share that
// tells classes apart, next to the mark: something transparent drawn over it dims both
// alike, and their ratio still gives the class.
const uint LABEL_LAYER = 1u << 19u;
const float LABELLED = 1024.0;
const float LABEL_STEP = 16.0;
const float CLASS_ROAD = 2.0;
const float CLASS_LANE_MARKING = 3.0;
const float CLASS_KERB = 4.0;
const float CLASS_TERRAIN = 5.0;
const float CLASS_VEGETATION = 6.0;
const float CLASS_SIGN = 9.0;

// Ends a fragment(): for the ground truth camera the surface shows its class and no light.
#define LABEL_AS(class_id) \
	if ((CAMERA_VISIBLE_LAYERS & LABEL_LAYER) == 0u) { \
		ALBEDO = vec3(0.0); \
		EMISSION = vec3(class_id * LABEL_STEP, LABELLED, 0.0); \
		ROUGHNESS = 1.0; \
		SPECULAR = 0.0; \
		METALLIC = 0.0; \
	}
