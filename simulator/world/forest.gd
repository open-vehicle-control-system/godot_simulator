class_name Forest
extends RefCounted
## A track's trees as impostors: each tree is a few crossed cards showing views of a tree,
## drawn in one batch per impostor.

const MIN_HEIGHT_M := 4.0
const BROADLEAF_WIDTH := 0.65  # of the impostor's own proportions
const RANDOM_SEED := 7
const SHADER := preload("res://world/shaders/impostor.gdshader")


static func build(trees: TreesSpec) -> Dictionary:
	## `{"forest": Node3D}` holding the trees of the pack, or `{"error": reason}`.
	var listed: Variant = JSON.parse_string(FileAccess.get_file_as_string(trees.instances_path))
	if not listed is Dictionary:
		return {"error": "%s is not a JSON object" % trees.instances_path.get_file()}
	var forest := Node3D.new()
	forest.name = "Forest"
	var random := RandomNumberGenerator.new()
	random.seed = RANDOM_SEED
	for kind in TreesSpec.KINDS:
		var impostors := trees.impostors.filter(func(impostor): return impostor.kind == kind)
		var standing: Variant = listed.get(kind, [])
		if impostors.is_empty() or not standing is Array:
			continue
		var per_impostor: Array[Array] = []
		per_impostor.resize(impostors.size())
		for tree in standing:
			per_impostor[random.randi() % impostors.size()].append(tree)
		for index in impostors.size():
			forest.add_child(_batch(impostors[index], per_impostor[index], random))
		forest.add_child(trunks(standing))
	return {"forest": forest}


static func trunks(standing: Array) -> TreeTrunks:
	## The trunks of the trees listed as [x, y, z, height] in the pack's ROS frame, as collision.
	var feet: Array[Vector3] = []
	for tree in standing:
		feet.append(standing_at(tree))
	return TreeTrunks.new(feet)


static func card_mesh(views: int, width_over_height: float) -> ArrayMesh:
	## Crossed cards of unit height about the trunk; card k shows the atlas's view k.
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for view in views:
		var angle := PI * view / views
		var half_width := Vector3(sin(angle), 0.0, cos(angle)) * width_over_height * 0.5
		var facing := Vector3(-cos(angle), 0.0, sin(angle))
		var left := float(view) / views
		var right := float(view + 1) / views
		var corners := [
			[-half_width, Vector2(left, 1.0)],
			[half_width, Vector2(right, 1.0)],
			[half_width + Vector3.UP, Vector2(right, 0.0)],
			[-half_width + Vector3.UP, Vector2(left, 0.0)],
		]
		for corner in [0, 1, 2, 0, 2, 3]:
			surface.set_normal(facing)
			surface.set_uv(corners[corner][1])
			surface.add_vertex(corners[corner][0])
	return surface.commit()


static func standing_at(tree: Array) -> Vector3:
	## Where a tree listed as [x, y, z, height] in the pack's ROS frame stands.
	return Vector3(tree[1], tree[2], tree[0])


static func _batch(
	impostor: TreesSpec.Impostor, standing: Array, random: RandomNumberGenerator
) -> MultiMeshInstance3D:
	var material := ShaderMaterial.new()
	material.shader = SHADER
	var atlas := Image.load_from_file(impostor.atlas_path)
	atlas.generate_mipmaps()
	material.set_shader_parameter("atlas", ImageTexture.create_from_image(atlas))
	var mesh := card_mesh(impostor.views, impostor.width_m / impostor.height_m)
	mesh.surface_set_material(0, material)
	var batch := MultiMesh.new()
	batch.transform_format = MultiMesh.TRANSFORM_3D
	batch.use_colors = true
	batch.mesh = mesh
	batch.instance_count = standing.size()
	var width := BROADLEAF_WIDTH if impostor.kind == "broadleaf" else 1.0
	for index in standing.size():
		var tree: Array = standing[index]
		var height_m := maxf(MIN_HEIGHT_M, tree[3]) * random.randf_range(0.95, 1.08)
		var basis := Basis(Vector3.UP, random.randf() * TAU).scaled(
			Vector3(height_m * width, height_m, height_m * width)
		)
		batch.set_instance_transform(index, Transform3D(basis, standing_at(tree)))
		var shade := random.randf_range(0.82, 1.08)
		batch.set_instance_color(
			index,
			Color(
				shade * random.randf_range(0.95, 1.05), shade, shade * random.randf_range(0.9, 1.0)
			)
		)
	var instance := MultiMeshInstance3D.new()
	instance.multimesh = batch
	return instance
