class_name Segmentation
extends RefCounted
## The classes of the segmentation image and how what is drawn carries one. A surface shows
## its class to the ground truth camera, the one whose cull mask lacks the label layer: the
## world's own shaders do it themselves (see label.gdshaderinc), any other material is given a
## label pass drawn over it. What has no label shows as unlabelled.

const UNLABELLED := 0
const SKY := 1
const ROAD := 2
const LANE_MARKING := 3
const KERB := 4
const TERRAIN := 5
const VEGETATION := 6
const BUILDING := 7
const STRUCTURE := 8
const SIGN := 9
const VEHICLE := 10
## Each class's name and its colour in the segmentation image, as 8-bit RGB.
const CLASSES: Array[Dictionary] = [
	{"name": "unlabelled", "colour": [0, 0, 0]},
	{"name": "sky", "colour": [70, 130, 180]},
	{"name": "road", "colour": [128, 64, 128]},
	{"name": "lane_marking", "colour": [157, 234, 50]},
	{"name": "kerb", "colour": [244, 35, 232]},
	{"name": "terrain", "colour": [152, 251, 152]},
	{"name": "vegetation", "colour": [107, 142, 35]},
	{"name": "building", "colour": [70, 70, 70]},
	{"name": "structure", "colour": [102, 102, 156]},
	{"name": "sign", "colour": [220, 220, 0]},
	{"name": "vehicle", "colour": [0, 0, 142]},
]
## The class of what each surface of a track pack's rules draws; the terrain surface tells
## road, paint and kerb from the ground pixel by pixel.
const SURFACE_CLASSES := {
	"roof": BUILDING, "facade": BUILDING, "seats": BUILDING, "plain": STRUCTURE
}
## The render layer no object is on, which only the ground truth camera does not see.
const LABEL_LAYER := 20
const ALL_LAYERS := (1 << 20) - 1
const LABEL_SHADER := preload("res://sensors/shaders/label.gdshader")

static var _label_passes: Dictionary[int, ShaderMaterial] = {}


static func label_pass(class_id: int) -> ShaderMaterial:
	## The material that shows `class_id` to the ground truth camera and nothing to the others.
	if not _label_passes.has(class_id):
		var material := ShaderMaterial.new()
		material.shader = LABEL_SHADER
		material.set_shader_parameter("class_id", float(class_id))
		material.render_priority = 1  # over the surface's own material, at the same depth
		_label_passes[class_id] = material
	return _label_passes[class_id]


static func label_under(root: Node, class_id: int) -> void:
	## Labels as `class_id` what every mesh under `root` is drawn with now, but what is seen
	## through: glass shows the class of what is behind it.
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var drawn := node as MeshInstance3D
		for surface in drawn.mesh.get_surface_count() if drawn.mesh != null else 0:
			var material := drawn.get_active_material(surface)
			if material == null:
				material = StandardMaterial3D.new()
				drawn.set_surface_override_material(surface, material)
			if not _seen_through(material):
				_last_pass(material).next_pass = label_pass(class_id)


static func _seen_through(material: Material) -> bool:
	var base := material as BaseMaterial3D
	return base != null and base.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA


static func _last_pass(material: Material) -> Material:
	while material.next_pass != null and not material.next_pass in _label_passes.values():
		material = material.next_pass
	return material


static func ground_truth_cull_mask() -> int:
	## The cull mask of the camera the labels are drawn for.
	return ALL_LAYERS & ~(1 << (LABEL_LAYER - 1))


static func described() -> Array:
	## The classes as calib.json lists them: `{"id", "name", "colour"}`.
	var classes := []
	for class_id in CLASSES.size():
		classes.append(
			{
				"id": class_id,
				"name": CLASSES[class_id]["name"],
				"colour": CLASSES[class_id]["colour"]
			}
		)
	return classes
