class_name RoadSigns
extends RefCounted
## A track's road signs and traffic signals: a batch of plates per face, one of posts, one of
## signal heads, and the posts as collision.

const SIGN_SHADER := preload("res://world/shaders/sign.gdshader")
const SIGNAL_SHADER := preload("res://world/shaders/signal.gdshader")
const POST_COLOUR := Color(0.5, 0.51, 0.52)
const POST_METALLIC := 0.7
const POST_ROUGHNESS := 0.5
const POST_SIDES := 10
const HOUSING_COLOUR := Color(0.03, 0.03, 0.03)
const BACKPLATE_EDGE_COLOUR := Color(0.85, 0.85, 0.83)
const BACKPLATE_EDGE_M := 0.04
const LENS_COLOURS := [Color(0.0, 1.0, 0.35), Color(1.0, 0.55, 0.0), Color(1.0, 0.04, 0.02)]
const LENS_SIDES := 20
# A signal head's proportions, in lens diameters.
const LENS_PITCH := 1.4
const HOUSING_WIDTH := 1.4
const HOUSING_DEPTH := 1.0
const BACKPLATE_MARGIN := 0.55


static func build(signs: SignsSpec) -> Dictionary:
	## `{"signs": Node3D}` holding the pack's signs and signals, or `{"error": reason}`.
	var file_name := signs.placed_path.get_file()
	var placed: Variant = JSON.parse_string(FileAccess.get_file_as_string(signs.placed_path))
	if not placed is Dictionary:
		return {"error": "%s is not a JSON object" % file_name}
	var reader := ManifestReader.new(file_name, placed)
	var root := Node3D.new()
	root.name = "RoadSigns"
	var plates_by_face := {}
	for plate in reader.readers("plates"):
		var face_id := plate.one_of("face", signs.faces.map(func(face): return face.id))
		var facing := _facing(plate)
		_keep_first_error(reader, plate)
		plates_by_face.get_or_add(face_id, []).append(facing)
	var posts := PostBodies.new()
	var post_transforms: Array[Transform3D] = []
	for post in reader.readers("posts"):
		var foot := post.ros_vector("position_m")
		var diameter_m := post.positive("diameter_m")
		var height_m := post.positive("height_m")
		_keep_first_error(reader, post)
		posts.add_post(foot, diameter_m, height_m)
		post_transforms.append(post_transform(foot, diameter_m, height_m))
	var heads: Array[Transform3D] = []
	var phases: Array[float] = []
	for head in reader.readers("signals"):
		heads.append(_facing(head))
		phases.append(head.number("phase"))
		_keep_first_error(reader, head)
	if reader.error != "":
		root.free()
		posts.free()
		return {"error": reader.error}
	for face_id in plates_by_face:
		root.add_child(_plates(signs.face(face_id), plates_by_face[face_id]))
	root.add_child(_batch("Posts", post_mesh(), post_transforms))
	root.add_child(posts)
	var signal_heads := _batch("Signals", signal_mesh(signs), heads)
	signal_heads.multimesh.use_custom_data = true
	signal_heads.multimesh.instance_count = heads.size()
	for index in heads.size():
		signal_heads.multimesh.set_instance_transform(index, heads[index])
		signal_heads.multimesh.set_instance_custom_data(index, Color(phases[index], 0.0, 0.0))
	root.add_child(signal_heads)
	return {"signs": root}


static func facing_transform(centre: Vector3, yaw_deg: float) -> Transform3D:
	## Where a plate or signal head is: at `centre`, its front (+Z) turned to the pack's yaw.
	# ROS yaw about z is Godot's turn about +Y from +Z towards +X.
	return Transform3D(Basis(Vector3.UP, deg_to_rad(yaw_deg)), centre)


static func post_transform(foot: Vector3, diameter_m: float, height_m: float) -> Transform3D:
	## What makes the unit post of `post_mesh` a post of this size standing on `foot`.
	return Transform3D(Basis.from_scale(Vector3(diameter_m, height_m, diameter_m)), foot)


static func plate_mesh(outline: PackedVector2Array) -> ArrayMesh:
	## A plate facing +Z: the convex `outline` as a fan, its image across its bounding box.
	var low := outline[0]
	var high := outline[0]
	for point in outline:
		low = low.min(point)
		high = high.max(point)
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for index in range(1, outline.size() - 1):
		# Godot's front faces wind clockwise; the outline runs counter-clockwise.
		for point in [outline[0], outline[index + 1], outline[index]]:
			surface.set_normal(Vector3.BACK)
			surface.set_uv(
				Vector2((point.x - low.x) / (high.x - low.x), (high.y - point.y) / (high.y - low.y))
			)
			surface.add_vertex(Vector3(point.x, point.y, 0.0))
	return surface.commit()


static func post_mesh() -> ArrayMesh:
	## A post one metre thick and tall standing on the origin, scaled to each post's size.
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = 0.5
	cylinder.bottom_radius = 0.5
	cylinder.height = 1.0
	cylinder.radial_segments = POST_SIDES
	cylinder.rings = 0
	var arrays := cylinder.get_mesh_arrays()
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	for index in vertices.size():
		vertices[index].y += 0.5
	arrays[Mesh.ARRAY_VERTEX] = vertices
	var steel := StandardMaterial3D.new()
	steel.albedo_color = POST_COLOUR
	steel.metallic = POST_METALLIC
	steel.roughness = POST_ROUGHNESS
	var standing := ArrayMesh.new()
	standing.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	standing.surface_set_material(0, steel)
	return standing


static func signal_mesh(signs: SignsSpec) -> ArrayMesh:
	## A three-aspect signal head facing +Z about its centre: a housing on a backplate edged
	## in white, and its lenses (red on top) as a second surface lit by the signal shader.
	var lens_m := signs.lens_diameter_m
	var housing := Vector3(HOUSING_WIDTH, 3.0 * LENS_PITCH, HOUSING_DEPTH) * lens_m
	var plate := Vector2(housing.x, housing.y) + Vector2.ONE * 2.0 * BACKPLATE_MARGIN * lens_m
	var body := SurfaceTool.new()
	body.begin(Mesh.PRIMITIVE_TRIANGLES)
	var box := BoxMesh.new()
	box.size = housing
	body.set_color(HOUSING_COLOUR)
	body.append_from(box, 0, Transform3D.IDENTITY)
	var back_z := -0.5 * housing.z
	_add_quad(body, plate, back_z, BACKPLATE_EDGE_COLOUR)
	_add_quad(body, plate - Vector2.ONE * 2.0 * BACKPLATE_EDGE_M, back_z + 0.004, HOUSING_COLOUR)
	_add_quad(body, plate, back_z - 0.004, HOUSING_COLOUR, -1.0)
	var paint := StandardMaterial3D.new()
	paint.vertex_color_use_as_albedo = true
	paint.roughness = 0.6
	var mesh := body.commit()
	mesh.surface_set_material(0, paint)
	var lenses := SurfaceTool.new()
	lenses.begin(Mesh.PRIMITIVE_TRIANGLES)
	for aspect in LENS_COLOURS.size():
		var centre := Vector3(0.0, (aspect - 1.0) * LENS_PITCH * lens_m, 0.5 * housing.z + 0.003)
		for side in LENS_SIDES:
			for corner in [Vector3.ZERO, _on_rim(side + 1), _on_rim(side)]:
				lenses.set_normal(Vector3.BACK)
				lenses.set_color(LENS_COLOURS[aspect])
				lenses.set_uv2(Vector2(aspect, 0.0))
				lenses.add_vertex(centre + corner * 0.5 * lens_m)
	var lit := ShaderMaterial.new()
	lit.shader = SIGNAL_SHADER
	lit.set_shader_parameter("green_s", signs.green_s)
	lit.set_shader_parameter("amber_s", signs.amber_s)
	lit.set_shader_parameter("red_s", signs.red_s)
	lenses.commit(mesh)
	mesh.surface_set_material(1, lit)
	return mesh


static func _add_quad(
	surface: SurfaceTool, size: Vector2, z: float, colour: Color, facing := 1.0
) -> void:
	var corners := [Vector2(-1, -1), Vector2(-1, 1), Vector2(1, 1), Vector2(1, -1)]
	for corner in [0, 1, 2, 0, 2, 3] if facing > 0.0 else [0, 2, 1, 0, 3, 2]:
		surface.set_normal(Vector3(0.0, 0.0, facing))
		surface.set_color(colour)
		surface.add_vertex(Vector3(corners[corner].x * size.x, corners[corner].y * size.y, z) * 0.5)


static func _on_rim(side: int) -> Vector3:
	var angle := TAU * side / LENS_SIDES
	return Vector3(cos(angle), sin(angle), 0.0)


static func _facing(placed: ManifestReader) -> Transform3D:
	return facing_transform(placed.ros_vector("position_m"), placed.number("yaw_deg"))


static func _keep_first_error(reader: ManifestReader, entry: ManifestReader) -> void:
	if reader.error == "":
		reader.error = entry.error


static func _plates(face: SignsSpec.Face, facings: Array) -> MultiMeshInstance3D:
	var image := Image.load_from_file(face.image_path)
	image.generate_mipmaps()
	var material := ShaderMaterial.new()
	material.shader = SIGN_SHADER
	material.set_shader_parameter("face", ImageTexture.create_from_image(image))
	var mesh := plate_mesh(face.outline)
	mesh.surface_set_material(0, material)
	var transforms: Array[Transform3D] = []
	transforms.assign(facings)
	return _batch("Plates %s" % face.id.validate_node_name(), mesh, transforms)


static func _batch(
	batch_name: String, mesh: Mesh, transforms: Array[Transform3D]
) -> MultiMeshInstance3D:
	var batch := MultiMesh.new()
	batch.transform_format = MultiMesh.TRANSFORM_3D
	batch.mesh = mesh
	batch.instance_count = transforms.size()
	for index in transforms.size():
		batch.set_instance_transform(index, transforms[index])
	var instance := MultiMeshInstance3D.new()
	instance.name = batch_name
	instance.multimesh = batch
	return instance
