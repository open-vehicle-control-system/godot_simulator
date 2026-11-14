class_name TileLoader
extends RefCounted
## Loads a tile of a track pack in two steps: `read_tile` reads its files, on a worker thread;
## `build_scene` makes them a scene drawn with the track's surfaces, on the main thread.

## A lot of obstacle triangles is closed once it holds this many: a shape of them is made
## within a couple of milliseconds.
const OBSTACLE_LOT_FACES := 3000
## The angles between normals under which the ground's coarser levels merge and split vertices.
const LEVEL_NORMAL_MERGE_DEG := 60.0
const LEVEL_NORMAL_SPLIT_DEG := 25.0

var _track: TrackSpec
var _materials: SurfaceMaterials
var _forest: Forest  # null for a track without trees
var _signs: RoadSigns  # null for a track without signs
var _decals: RoadDecals  # null for a track without decals


func _init(
	track: TrackSpec,
	materials: SurfaceMaterials,
	forest: Forest,
	signs: RoadSigns,
	decals: RoadDecals = null
) -> void:
	_track = track
	_materials = materials
	_forest = forest
	_signs = signs
	_decals = decals


func read_tile(tile: TilesSpec.Tile) -> TileContent:
	## The tile as its files hold it; its `error` tells what is wrong with them. Touches
	## neither the scene tree nor a server, so it runs on a worker thread.
	var content := TileContent.new()
	content.tile = tile
	content.error = _read(content)
	if content.error != "":
		content.error = "%s: tile %s: %s" % [_track.id, tile.key, content.error]
	return content


func build_scene(content: TileContent) -> void:
	## Builds the scene of a tile that was read without error. On the main thread.
	content.scene = content.document.generate_scene(content.state) as Node3D
	content.scene.name = "Tile_%s" % content.tile.key
	_mark_ground(content.scene)
	_materials.apply(content.scene, content.ground_images)
	for batch in content.batches:
		content.scene.add_child(batch.instantiate())
	if not content.decals.is_empty():
		content.scene.add_child(_decals.lay(content.decals))
		content.decals = []
	content.document = null
	content.state = null
	content.ground_images = {}
	content.batches = []


func _read(content: TileContent) -> String:
	var tile := content.tile
	content.document = GLTFDocument.new()
	content.state = GLTFState.new()
	if content.document.append_from_file(tile.path(".glb"), content.state) != OK:
		return "%s does not load" % tile.path(".glb").get_file()
	_read_obstacles(content, content.state)
	_add_ground_levels(content.state)
	var ground := _materials.read_ground(content.state, tile)
	if ground.has("error"):
		return ground["error"]
	content.ground_images = ground["images"]
	var samples := _track.tiles.ground_samples()
	var heights_m := FileAccess.get_file_as_bytes(tile.path(".ground.f32")).to_float32_array()
	if heights_m.size() != samples * samples:
		return "%s does not hold %d by %d heights" % [tile.key + ".ground.f32", samples, samples]
	content.ground_patches = GroundPatch.split(heights_m, samples)
	return _stand_objects(content)


func _read_obstacles(content: TileContent, state: GLTFState) -> void:
	## Every mesh the terrain surface does not draw collides as it is drawn.
	var nodes := state.get_nodes()
	var meshes := state.get_meshes()
	for index in nodes.size():
		if nodes[index].mesh < 0:
			continue
		var mesh := meshes[nodes[index].mesh].mesh
		if _is_ground(nodes[index].resource_name, mesh):
			continue
		var placed := _transform_in_scene(nodes, index)
		for surface in mesh.get_surface_count():
			if mesh.get_surface_primitive_type(surface) != Mesh.PRIMITIVE_TRIANGLES:
				continue
			var lots := content.obstacle_faces
			if lots.is_empty() or lots[-1].size() >= OBSTACLE_LOT_FACES * 3:
				lots.append(PackedVector3Array())
			_append_faces(lots[-1], mesh.get_surface_arrays(surface), placed)


func _add_ground_levels(state: GLTFState) -> void:
	## Gives the ground's meshes coarser levels, which the renderer draws once their error is
	## under a pixel. A level keeps every vertex of its mesh's border, so neighbouring tiles
	## drawn at different levels meet without a crack.
	var meshes := state.get_meshes()
	for node in state.get_nodes():
		if node.mesh >= 0 and _is_ground(node.resource_name, meshes[node.mesh].mesh):
			meshes[node.mesh].mesh.generate_lods(LEVEL_NORMAL_MERGE_DEG, LEVEL_NORMAL_SPLIT_DEG, [])


func _mark_ground(scene: Node3D) -> void:
	## Puts the ground's meshes on the layer decals project onto, besides their own.
	for node in scene.find_children("*", "MeshInstance3D", true, false):
		var drawn := node as MeshInstance3D
		var is_ground := drawn.mesh != null and drawn.mesh.get_surface_count() > 0
		for surface in drawn.mesh.get_surface_count() if drawn.mesh != null else 0:
			var material := drawn.mesh.surface_get_material(surface)
			var rule := _track.surface_rule(drawn.name, material.resource_name if material else "")
			is_ground = is_ground and rule != null and rule.kind == "terrain"
		if is_ground:
			drawn.layers |= RoadDecals.GROUND_LAYER


func _is_ground(mesh_name: String, mesh: ImporterMesh) -> bool:
	for surface in mesh.get_surface_count():
		var drawn := mesh.get_surface_material(surface)
		var rule := _track.surface_rule(mesh_name, drawn.resource_name if drawn else "")
		if rule == null or rule.kind != "terrain":
			return false
	return mesh.get_surface_count() > 0


static func _transform_in_scene(nodes: Array[GLTFNode], index: int) -> Transform3D:
	var placed := Transform3D.IDENTITY
	while index >= 0:
		placed = nodes[index].xform * placed
		index = nodes[index].parent
	return placed


static func _append_faces(faces: PackedVector3Array, arrays: Array, placed: Transform3D) -> void:
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	if not placed.is_equal_approx(Transform3D.IDENTITY):
		vertices = placed * vertices
	if arrays[Mesh.ARRAY_INDEX] == null:
		faces.append_array(vertices)
		return
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var first := faces.size()
	faces.resize(first + indices.size())
	for corner in indices.size():
		faces[first + corner] = vertices[indices[corner]]


func _stand_objects(content: TileContent) -> String:
	if _forest == null and _signs == null and _decals == null:
		return ""
	var file_name := content.tile.key + ".json"
	var standing: Variant = JSON.parse_string(
		FileAccess.get_file_as_string(content.tile.path(".json"))
	)
	if not standing is Dictionary:
		return "%s is not a JSON object" % file_name
	if _forest != null:
		var trees: Variant = standing.get("trees")
		if not trees is Dictionary:
			return "%s: trees is missing or not an object" % file_name
		content.batches.append_array(_forest.tile_trees(trees, content.tile.key.hash()))
		content.trunk_feet = Forest.feet(trees)
	if _signs != null:
		var stood := _signs.tile_signs(standing, file_name)
		if stood.has("error"):
			return stood["error"]
		content.batches.append_array(stood["batches"])
		content.post_feet = stood["post_feet"]
		content.post_sizes = stood["post_sizes"]
	if _decals != null:
		var laid := _decals.tile_decals(standing, file_name)
		if laid.has("error"):
			return laid["error"]
		content.decals = laid["decals"]
	return ""
