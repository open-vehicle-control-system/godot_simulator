class_name Forest
extends RefCounted
## A track's trees as impostors: each tree is a few crossed cards showing views of a tree,
## drawn in a batch per impostor and cluster of trees, so that what is behind the camera or
## beyond the draw distance is not drawn. Shadows are cast by the cards' silhouettes as plain
## triangles: a shadow map takes those many times faster than cards cut out by a texture.

const MIN_HEIGHT_M := 4.0
const BROADLEAF_WIDTH := 0.65  # of the impostor's own proportions
const RANDOM_SEED := 7
const CLUSTER_M := 64.0
## Around a cluster's centre, whatever its trees reach.
const CLUSTER_REACH_M := CLUSTER_M
const SILHOUETTE_ROWS := 32
const OPAQUE_ALPHA := 0.45
## The share of the draw distance, at its end, over which a tree shrinks away.
const FADE_SHARE := 0.2
const SHADER := preload("res://world/shaders/impostor.gdshader")

var _impostors: Array[TreesSpec.Impostor] = []
var _meshes: Array[ArrayMesh] = []  # an impostor's cards, drawn with its atlas
var _silhouettes: Array[ArrayMesh] = []  # what casts an impostor's shadow; null without any
var _draw_distance_m := 0.0  # 0 when trees are drawn wherever they stand


static func create(trees: TreesSpec) -> Dictionary:
	## `{"forest": Forest}` drawing trees with the pack's impostors, or `{"error": reason}`.
	var forest := Forest.new()
	forest._draw_distance_m = trees.draw_distance_m
	var hidden := StandardMaterial3D.new()
	hidden.cull_mode = BaseMaterial3D.CULL_DISABLED
	for impostor in trees.impostors:
		var atlas := SurfaceMaterials.load_dds(impostor.atlas_path)
		if atlas == null:
			return {"error": "%s does not load" % impostor.atlas_path.get_file()}
		var material := ShaderMaterial.new()
		material.shader = SHADER
		material.set_shader_parameter("atlas", ImageTexture.create_from_image(atlas))
		if trees.draw_distance_m > 0.0:
			material.set_shader_parameter("fades_from_m", fade_start_m(trees.draw_distance_m))
			material.set_shader_parameter("gone_at_m", trees.draw_distance_m)
		var proportions := impostor.width_m / impostor.height_m
		var mesh := card_mesh(impostor.views, proportions)
		mesh.surface_set_material(0, material)
		var opaque := opaque_cells(atlas, impostor.views * _silhouette_columns(proportions))
		var silhouette := silhouette_mesh(opaque, impostor.views, proportions)
		if silhouette != null:
			silhouette.surface_set_material(0, hidden)
		forest._impostors.append(impostor)
		forest._meshes.append(mesh)
		forest._silhouettes.append(silhouette)
	return {"forest": forest}


func tile_trees(standing: Dictionary, random_seed: int) -> Array[InstanceBatch]:
	## The trees a tile lists by kind, each [x, y, z, height] in the pack's ROS frame, as
	## batches per impostor and cluster: the trees, and what casts their shadows. Reads only
	## what `create` set up, so it runs on any thread.
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
			batches.append_array(_clusters(of_kind[slot], per_impostor[slot], random))
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
		var left := float(view) / views
		var right := float(view + 1) / views
		_add_card_piece(
			surface, view, views, width_over_height, Rect2(left, 0.0, right - left, 1.0)
		)
	return surface.commit()


static func opaque_cells(atlas: Image, columns: int) -> BitMap:
	## Where an impostor's atlas is opaque, on a grid of `columns` by SILHOUETTE_ROWS cells,
	## read from the smallest of its mipmaps that shows as much.
	var level := 0
	while (
		level + 1 < atlas.get_mipmap_count() + 1
		and (atlas.get_width() >> (level + 1)) >= columns
		and (atlas.get_height() >> (level + 1)) >= SILHOUETTE_ROWS
	):
		level += 1
	var small := _mipmap(atlas, level)
	if small.is_compressed():
		small.decompress()
	small.convert(Image.FORMAT_RGBA8)
	small.resize(columns, SILHOUETTE_ROWS, Image.INTERPOLATE_BILINEAR)
	var opaque := BitMap.new()
	opaque.create_from_image_alpha(small, OPAQUE_ALPHA)
	return opaque


static func silhouette_mesh(opaque: BitMap, views: int, width_over_height: float) -> ArrayMesh:
	## The cards of `card_mesh` kept only where the atlas is `opaque`: a rectangle per run of
	## opaque cells, as tall as the rows that repeat it. Null where nothing is opaque.
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var size := opaque.get_size()
	var columns := size.x / views
	var pieces := 0
	for view in views:
		for cells in opaque_rectangles(opaque, Rect2i(view * columns, 0, columns, size.y)):
			var shown := Rect2(cells.position, cells.size)
			shown.position /= Vector2(size)
			shown.size /= Vector2(size)
			_add_card_piece(surface, view, views, width_over_height, shown)
			pieces += 1
	return surface.commit() if pieces > 0 else null


static func opaque_rectangles(opaque: BitMap, within: Rect2i) -> Array[Rect2i]:
	## The set cells of `opaque` inside `within`, covered once by rectangles: each run of set
	## cells in a row, joined with the same run in the rows under it.
	var rectangles: Array[Rect2i] = []
	var open: Dictionary[Vector2i, int] = {}  # a run's (first column, length) -> its rectangle
	for row in range(within.position.y, within.end.y):
		var continued: Dictionary[Vector2i, int] = {}
		for run in _runs(opaque, row, within.position.x, within.end.x):
			if open.has(run):
				rectangles[open[run]].size.y += 1
			else:
				open[run] = rectangles.size()
				rectangles.append(Rect2i(run.x, row, run.y, 1))
			continued[run] = open[run]
		open = continued
	return rectangles


static func standing_at(tree: Array) -> Vector3:
	## Where a tree listed as [x, y, z, height] in the pack's ROS frame stands.
	return Vector3(tree[1], tree[2], tree[0])


static func fade_start_m(draw_distance_m: float) -> float:
	## How far a tree drawn up to `draw_distance_m` starts to fade.
	return draw_distance_m * (1.0 - FADE_SHARE)


static func _silhouette_columns(width_over_height: float) -> int:
	return maxi(1, roundi(SILHOUETTE_ROWS * width_over_height))


static func _mipmap(image: Image, level: int) -> Image:
	if level == 0:
		return image.duplicate()
	var first := image.get_mipmap_offset(level)
	var end := image.get_data().size()
	if level < image.get_mipmap_count():
		end = image.get_mipmap_offset(level + 1)
	return Image.create_from_data(
		maxi(1, image.get_width() >> level),
		maxi(1, image.get_height() >> level),
		false,
		image.get_format(),
		image.get_data().slice(first, end)
	)


static func _runs(opaque: BitMap, row: int, first: int, end: int) -> Array[Vector2i]:
	## The runs of set cells in a row between two columns, each (first column, length).
	var runs: Array[Vector2i] = []
	var start := -1
	for column in range(first, end + 1):
		var is_set := column < end and opaque.get_bit(column, row)
		if is_set and start < 0:
			start = column
		elif not is_set and start >= 0:
			runs.append(Vector2i(start, column - start))
			start = -1
	return runs


static func _add_card_piece(
	surface: SurfaceTool, view: int, views: int, width_over_height: float, shown: Rect2
) -> void:
	## Adds the part of card `view` that shows the atlas's rectangle `shown`, in UV.
	var angle := PI * view / views
	var across := Vector3(sin(angle), 0.0, cos(angle)) * width_over_height
	var facing := Vector3(-cos(angle), 0.0, sin(angle))
	var corners: Array[Vector2] = [
		Vector2(shown.position.x, shown.end.y),
		Vector2(shown.end.x, shown.end.y),
		shown.end - Vector2(0.0, shown.size.y),
		shown.position,
	]
	for corner in [0, 1, 2, 0, 2, 3]:
		var uv := corners[corner]
		surface.set_normal(facing)
		surface.set_uv(uv)
		surface.add_vertex(across * (uv.x * views - view - 0.5) + Vector3.UP * (1.0 - uv.y))


func _clusters(index: int, standing: Array, random: RandomNumberGenerator) -> Array[InstanceBatch]:
	## The trees drawn with one impostor, as two batches per cluster they stand in.
	var impostor := _impostors[index]
	var width := BROADLEAF_WIDTH if impostor.kind == "broadleaf" else 1.0
	var drawn: Dictionary[Vector2i, InstanceBatch] = {}
	var shadows: Dictionary[Vector2i, InstanceBatch] = {}
	for tree: Array in standing:
		var height_m := maxf(MIN_HEIGHT_M, tree[3]) * random.randf_range(0.95, 1.08)
		var basis := Basis(Vector3.UP, random.randf() * TAU).scaled(
			Vector3(height_m * width, height_m, height_m * width)
		)
		var shade := random.randf_range(0.82, 1.08)
		var tint := Color(
			shade * random.randf_range(0.95, 1.05), shade, shade * random.randf_range(0.9, 1.0)
		)
		var foot := standing_at(tree)
		var cluster := Vector2i((Vector2(foot.x, foot.z) / CLUSTER_M).floor())
		if not drawn.has(cluster):
			var centre := Vector3(
				(cluster.x + 0.5) * CLUSTER_M, foot.y, (cluster.y + 0.5) * CLUSTER_M
			)
			drawn[cluster] = _drawn_batch(index, cluster, centre)
			shadows[cluster] = _shadow_batch(index, cluster, centre)
		drawn[cluster].add(Transform3D(basis, foot), tint)
		shadows[cluster].add(Transform3D(basis, foot))
	var batches: Array[InstanceBatch] = []
	batches.append_array(drawn.values())
	if _silhouettes[index] != null:
		batches.append_array(shadows.values())
	return batches


func _drawn_batch(index: int, cluster: Vector2i, centre: Vector3) -> InstanceBatch:
	var batch := InstanceBatch.new(
		"Trees %d at %d %d" % [index, cluster.x, cluster.y], _meshes[index], true
	)
	batch.centre = centre
	batch.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if _draw_distance_m > 0.0:
		batch.visible_within_m = _draw_distance_m + CLUSTER_REACH_M
	return batch


func _shadow_batch(index: int, cluster: Vector2i, centre: Vector3) -> InstanceBatch:
	var batch := InstanceBatch.new(
		"Tree shadows %d at %d %d" % [index, cluster.x, cluster.y], _silhouettes[index]
	)
	batch.centre = centre
	batch.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
	batch.visible_within_m = TrackWorld.SHADOW_DISTANCE_M + CLUSTER_REACH_M
	return batch
