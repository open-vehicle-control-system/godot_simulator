class_name Forest
extends RefCounted
## A track's trees as impostors: each tree is a few crossed cards showing views of a tree,
## drawn tile by tile in one batch per impostor.

const MIN_HEIGHT_M := 4.0
const BROADLEAF_WIDTH := 0.65  # of the impostor's own proportions
const RANDOM_SEED := 7
const SHADER := preload("res://world/shaders/impostor.gdshader")

var _impostors: Array[TreesSpec.Impostor] = []
var _meshes: Array[ArrayMesh] = []  # an impostor's cards, drawn with its atlas


static func create(trees: TreesSpec) -> Dictionary:
	## `{"forest": Forest}` drawing trees with the pack's impostors, or `{"error": reason}`.
	var forest := Forest.new()
	for impostor in trees.impostors:
		var atlas := SurfaceMaterials.load_dds(impostor.atlas_path)
		if atlas == null:
			return {"error": "%s does not load" % impostor.atlas_path.get_file()}
		var material := ShaderMaterial.new()
		material.shader = SHADER
		material.set_shader_parameter("atlas", ImageTexture.create_from_image(atlas))
		var mesh := card_mesh(impostor.views, impostor.width_m / impostor.height_m)
		mesh.surface_set_material(0, material)
		forest._impostors.append(impostor)
		forest._meshes.append(mesh)
	return {"forest": forest}


func tile_trees(standing: Dictionary, random_seed: int) -> Array[InstanceBatch]:
	## The trees a tile lists by kind, each [x, y, z, height] in the pack's ROS frame, as a
	## batch per impostor. Reads only what `create` set up, so it runs on any thread.
	var batches: Array[InstanceBatch] = []
	var random := RandomNumberGenerator.new()
	random.seed = random_seed
	for kind in TreesSpec.KINDS:
		var of_kind := range(_impostors.size()).filter(
			func(index): return _impostors[index].kind == kind
		)
		var trees: Variant = standing.get(kind, [])
		if of_kind.is_empty() or not trees is Array or trees.is_empty():
			continue
		var per_impostor: Array[Array] = []
		per_impostor.resize(of_kind.size())
		for tree in trees:
			per_impostor[random.randi() % of_kind.size()].append(tree)
		for slot in of_kind.size():
			if not per_impostor[slot].is_empty():
				batches.append(_batch(of_kind[slot], per_impostor[slot], random))
	return batches


static func feet(standing: Dictionary) -> Array[Vector3]:
	## Where the trees a tile lists by kind stand.
	var stood: Array[Vector3] = []
	for kind in TreesSpec.KINDS:
		var trees: Variant = standing.get(kind, [])
		if trees is Array:
			for tree in trees:
				stood.append(standing_at(tree))
	return stood


static func trunks(standing: Array) -> TreeTrunks:
	## The trunks of the trees listed as [x, y, z, height] in the pack's ROS frame, as collision.
	var stood: Array[Vector3] = []
	for tree in standing:
		stood.append(standing_at(tree))
	return TreeTrunks.new(stood)


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


func _batch(index: int, standing: Array, random: RandomNumberGenerator) -> InstanceBatch:
	var impostor := _impostors[index]
	var batch := InstanceBatch.new("Trees %d" % index, _meshes[index], true)
	var width := BROADLEAF_WIDTH if impostor.kind == "broadleaf" else 1.0
	for tree: Array in standing:
		var height_m := maxf(MIN_HEIGHT_M, tree[3]) * random.randf_range(0.95, 1.08)
		var basis := Basis(Vector3.UP, random.randf() * TAU).scaled(
			Vector3(height_m * width, height_m, height_m * width)
		)
		var shade := random.randf_range(0.82, 1.08)
		batch.add(
			Transform3D(basis, standing_at(tree)),
			Color(
				shade * random.randf_range(0.95, 1.05), shade, shade * random.randf_range(0.9, 1.0)
			)
		)
	return batch
