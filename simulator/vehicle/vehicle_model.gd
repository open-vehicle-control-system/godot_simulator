class_name VehicleModel
extends RefCounted
## The meshes a vehicle shows: its body, one wheel the vehicle copies to each corner, and the
## cockpit parts that move (`Cockpit_*`), from the pack's glTF or a box and cylinders.
##
## In the glTF, `Body` and `Cockpit_*` sit where they are on the vehicle; `Wheel` is centred on
## its axle at the origin, its outer face towards +X (the left side).

const PLACEHOLDER_PAINT := Color(0.12, 0.54, 0.54)
const PLACEHOLDER_RUBBER := Color(0.05, 0.05, 0.05)

var body: Node3D
var wheel: Node3D
var cockpit_parts: Array[Node3D] = []


static func build(spec: VehicleSpec) -> Dictionary:
	## `{"model": VehicleModel}`, or `{"error": reason}` when the pack's glTF is unusable.
	return build_from(spec, read(spec))


static func read(spec: VehicleSpec) -> Dictionary:
	## What `build_from` builds the model from: the pack's glTF as parsed, `{}` for a pack
	## without one, or `{"error": reason}`. Touches no scene, so it runs on a worker thread.
	if spec.model_path == "":
		return {}
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	if document.append_from_file(spec.model_path, state) != OK:
		return {"error": "%s: %s does not load" % [spec.id, spec.model_path.get_file()]}
	return {"document": document, "state": state}


static func build_from(spec: VehicleSpec, parsed: Dictionary) -> Dictionary:
	## `{"model": VehicleModel}` from what `read` returned, or `{"error": reason}`.
	if parsed.has("error"):
		return parsed
	if parsed.is_empty():
		return {"model": _placeholder(spec)}
	return _from_gltf(spec, parsed["document"], parsed["state"])


func free_all() -> void:
	## Frees the meshes not added to a scene.
	for part in [body, wheel] + cockpit_parts:
		if is_instance_valid(part) and part.get_parent() == null:
			part.free()


static func _from_gltf(spec: VehicleSpec, document: GLTFDocument, state: GLTFState) -> Dictionary:
	var file_name := spec.model_path.get_file()
	var scene := document.generate_scene(state)
	var model := VehicleModel.new()
	model.body = _detach(scene, scene.find_child("Body", true, false))
	model.wheel = _detach(scene, scene.find_child("Wheel", true, false))
	for part in scene.find_children("Cockpit_*", "Node3D", true, false):
		model.cockpit_parts.append(_detach(scene, part))
	scene.free()
	for required in ["body", "wheel"]:
		if model.get(required) == null:
			model.free_all()
			return {"error": "%s: %s has no %s node" % [spec.id, file_name, required.capitalize()]}
	model.wheel.transform = Transform3D.IDENTITY
	return {"model": model}


static func _detach(scene: Node3D, node: Node) -> Node3D:
	## `node` out of `scene`, keeping where it sits relative to the scene's root.
	if node == null or not node is Node3D:
		return null
	var placed := Transform3D.IDENTITY
	var ancestor: Node = node
	while ancestor != scene:
		placed = (ancestor as Node3D).transform * placed
		ancestor = ancestor.get_parent()
	node.get_parent().remove_child(node)
	node.owner = null
	node.transform = placed
	return node


static func _placeholder(spec: VehicleSpec) -> VehicleModel:
	var model := VehicleModel.new()
	var box := BoxMesh.new()
	box.size = spec.body_size
	box.material = _paint(PLACEHOLDER_PAINT)
	var body := MeshInstance3D.new()
	body.name = "Body"
	body.mesh = box
	body.position = spec.body_centre
	model.body = body
	var tyre := CylinderMesh.new()
	tyre.top_radius = spec.wheel_radius_m
	tyre.bottom_radius = spec.wheel_radius_m
	tyre.height = spec.wheel_width_m
	tyre.material = _paint(PLACEHOLDER_RUBBER)
	var cylinder := MeshInstance3D.new()
	cylinder.mesh = tyre
	cylinder.rotation_degrees = Vector3(0.0, 0.0, 90.0)  # axle along X
	model.wheel = Node3D.new()
	model.wheel.name = "Wheel"
	model.wheel.add_child(cylinder)
	return model


static func _paint(colour: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = colour
	return material
