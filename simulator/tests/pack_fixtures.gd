class_name PackFixtures
extends RefCounted
## Writes small packs for tests into a fresh directory: a vehicle sized like a small car and a
## flat track, all generated, with nothing third-party.


static func fresh_directory(test_name: String) -> String:
	## An empty directory under user:// for one test.
	var directory := OS.get_user_data_dir().path_join("test_packs").path_join(test_name)
	if DirAccess.dir_exists_absolute(directory):
		OS.move_to_trash(directory)
	DirAccess.make_dir_recursive_absolute(directory)
	return directory


static func vehicle_manifest(id: String) -> Dictionary:
	## A valid vehicle manifest: a small car, its origin 1.3 m ahead of the rear axle.
	return {
		"format": 1,
		"kind": "vehicle",
		"id": id,
		"name": "Test vehicle",
		"version": "1.0.0",
		"licence": "CC0-1.0",
		"attribution": [],
		"vehicle":
		{
			"front_axle_x_m": 1.2,
			"rear_axle_x_m": -1.3,
			"front_track_m": 1.4,
			"rear_track_m": 1.4,
			"wheel_radius_m": 0.3,
			"wheel_width_m": 0.2,
			"max_lateral_acceleration_m_s2": 8.0,
			"body": {"size_m": [3.9, 1.6, 1.0], "centre_m": [0.0, 0.0, 0.85]},
			"driver_eye_m": [-0.2, 0.38, 1.1],
			"driver_pitch_deg": -3.0,
			"stereo":
			{
				"mount_m": [0.6, 0.0, 1.16],
				"width_px": 320,
				"height_px": 180,
				"hfov_deg": 90.0,
				"baseline_m": 0.12,
				"pitch_deg": 0.0,
				"rate_hz": 10.0,
			},
		},
	}


static func cockpit_manifest(id: String) -> Dictionary:
	## `vehicle_manifest` with the model `write_cockpit_model` writes, its instruments and its
	## mirrors.
	var manifest := vehicle_manifest(id)
	manifest["vehicle"]["model"] = "vehicle.glb"
	manifest["vehicle"]["instruments"] = {
		"speedometer":
		{
			"node": "Cockpit_Speed",
			"axis": [1.0, 0.0, 0.0],
			"km_h_to_deg": [[0, 0.0], [100, 120.0], [200, 200.0]],
		},
		"rev_counter":
		{
			"node": "Cockpit_Revs",
			"axis": [1.0, 0.0, 0.0],
			"deg_per_rpm": 0.05,
			"max_rpm": 6000,
			"motor_to_wheel_ratio": 8.0,
		},
		"steering_wheel":
		{"node": "Cockpit_Steer", "axis": [-1.0, 0.0, 0.0], "ratio": 16.0, "lock_deg": 500.0},
	}
	manifest["vehicle"]["mirrors"] = {
		"material": "Mirror_Glass", "interior_hfov_deg": 45.0, "door_hfov_deg": 30.0
	}
	return manifest


static func track_manifest(id: String) -> Dictionary:
	## A valid track manifest naming tiles.json and a spawn at the origin.
	return {
		"format": 1,
		"kind": "track",
		"id": id,
		"name": "Test track",
		"version": "1.0.0",
		"licence": "CC0-1.0",
		"attribution": [],
		"track": {"tiles": "tiles.json", "spawn": {"position_m": [0.0, 0.0, 0.0], "yaw_deg": 0.0}},
	}


static func write_pack(directory: String, manifest: Dictionary) -> String:
	## Writes `manifest` as a pack under `directory`; returns the pack's directory.
	var pack_directory := directory.path_join(manifest["id"])
	DirAccess.make_dir_recursive_absolute(pack_directory)
	var file := FileAccess.open(pack_directory.path_join("pack.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(manifest, "  "))
	return pack_directory


static func write_vehicle_model(pack_directory: String) -> void:
	## vehicle.glb: a `Body` box, a `Wheel` cylinder and a `Cockpit_Steer` node.
	var root := Node3D.new()
	root.name = "Vehicle"
	_add_mesh(root, "Body", _box(Vector3(1.6, 1.0, 3.9)), Vector3(0.0, 0.85, 0.0))
	var wheel := CylinderMesh.new()
	wheel.top_radius = 0.3
	wheel.bottom_radius = 0.3
	wheel.height = 0.2
	_add_mesh(root, "Wheel", wheel, Vector3.ZERO)
	_add_mesh(root, "Cockpit_Steer", _box(Vector3(0.35, 0.35, 0.05)), Vector3(0.38, 0.9, 0.3))
	_write_gltf(root, pack_directory.path_join("vehicle.glb"))


static func write_cockpit_model(pack_directory: String) -> void:
	## vehicle.glb: a `Body` box carrying three pieces of glass drawn with `Mirror_Glass` (a
	## door mirror 0.9 m either side of the centreline and an interior one), a `Wheel` and the
	## cockpit parts `Cockpit_Speed`, `Cockpit_Revs` and `Cockpit_Steer`.
	var root := Node3D.new()
	root.name = "Vehicle"
	var body := ArrayMesh.new()
	body.add_surface_from_arrays(
		Mesh.PRIMITIVE_TRIANGLES, _box(Vector3(1.6, 1.0, 3.9)).get_mesh_arrays()
	)
	var glass := SurfaceTool.new()
	glass.begin(Mesh.PRIMITIVE_TRIANGLES)
	for centre in [Vector3(0.9, 0.2, 0.5), Vector3(0.0, 0.4, 0.4), Vector3(-0.9, 0.2, 0.5)]:
		for corner in [[-1, -1], [1, -1], [1, 1], [-1, -1], [1, 1], [-1, 1]]:
			glass.add_vertex(centre + Vector3(corner[0] * 0.1, corner[1] * 0.05, 0.0))
	var silver := StandardMaterial3D.new()
	silver.resource_name = "Mirror_Glass"
	glass.set_material(silver)
	glass.commit(body)
	_add_mesh(root, "Body", body, Vector3(0.0, 0.85, 0.0))
	var wheel := CylinderMesh.new()
	wheel.top_radius = 0.3
	wheel.bottom_radius = 0.3
	wheel.height = 0.2
	_add_mesh(root, "Wheel", wheel, Vector3.ZERO)
	for part in ["Cockpit_Speed", "Cockpit_Revs", "Cockpit_Steer"]:
		_add_mesh(root, part, _box(Vector3(0.05, 0.05, 0.01)), Vector3(0.38, 0.9, 0.3))
	_write_gltf(root, pack_directory.path_join("vehicle.glb"))


static func write_flat_world(pack_directory: String, size_m: float) -> void:
	## One tile `a`: a flat square of ground `size_m` wide, centred on the origin, at height 0.
	var corner := Vector2(-0.5, -0.5) * size_m
	write_tile_index(pack_directory, size_m, size_m * 0.5, {"a": corner})
	write_flat_tile(pack_directory, "a", corner, size_m, 0.0, "Ground", "")


static func write_photo_world(pack_directory: String, material_name: String, maps := []) -> void:
	## One tile `a` with the ground maps `maps`: a flat square of ground named `Terrain_a`,
	## 20 m wide, drawn with a material named `material_name`.
	var corner := Vector2(-10.0, -10.0)
	write_tile_index(pack_directory, 20.0, 10.0, {"a": corner}, maps)
	write_flat_tile(pack_directory, "a", corner, 20.0, 0.0, "Terrain_a", material_name)


static func write_tile_index(
	pack_directory: String,
	tile_size_m: float,
	ground_step_m: float,
	corners: Dictionary,
	maps := []
) -> void:
	## tiles.json listing a tile per key of `corners`, each at its (x, z) corner in Godot's
	## frame, holding what lies within 100 m of height 0 over its square.
	var tiles := []
	for key in corners:
		var corner: Vector2 = corners[key]
		(
			tiles
			. append(
				{
					"key": key,
					"corner_m": [corner.y, corner.x],
					"bounds_m":
					[
						[corner.y, corner.x, -100.0],
						[corner.y + tile_size_m, corner.x + tile_size_m, 100.0]
					],
					"maps": maps,
				}
			)
		)
	var index := {"tile_size_m": tile_size_m, "ground_step_m": ground_step_m, "tiles": tiles}
	var file := FileAccess.open(pack_directory.path_join("tiles.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(index))


static func write_flat_tile(
	pack_directory: String,
	key: String,
	corner: Vector2,
	size_m: float,
	height_m: float,
	mesh_name: String,
	material_name: String
) -> void:
	## A tile's scene and ground: a flat square `size_m` wide at `height_m`, its mesh named
	## `mesh_name` and drawn with a material named `material_name` unless that is "". The
	## ground's heights are three by three.
	var directory := pack_directory.path_join("tiles")
	DirAccess.make_dir_recursive_absolute(directory)
	var root := Node3D.new()
	root.name = "Tile"
	var ground := PlaneMesh.new()
	ground.size = Vector2(size_m, size_m)
	if material_name != "":
		var material := StandardMaterial3D.new()
		material.resource_name = material_name
		ground.material = material
	var centre := corner + Vector2.ONE * size_m * 0.5
	_add_mesh(root, mesh_name, ground, Vector3(centre.x, height_m, centre.y))
	_write_gltf(root, directory.path_join(key + ".glb"))
	var heights := PackedFloat32Array()
	heights.resize(9)
	heights.fill(height_m)
	var file := FileAccess.open(directory.path_join(key + ".ground.f32"), FileAccess.WRITE)
	file.store_buffer(heights.to_byte_array())


static func write_ridge_world(
	pack_directory: String, ridge_height_m: float, wall_face_z: float
) -> void:
	## One tile `a`, 40 m wide and centred on the origin: flat ground whose heights rise to
	## `ridge_height_m` along the line x = 0, between a vehicle's wheels, and a wall across that
	## line, a mesh of the tile, its near face at `wall_face_z`.
	var size_m := 40.0
	var step_m := 0.5
	var corner := Vector2(-0.5, -0.5) * size_m
	write_tile_index(pack_directory, size_m, step_m, {"a": corner})
	DirAccess.make_dir_recursive_absolute(pack_directory.path_join("tiles"))
	var root := Node3D.new()
	root.name = "Tile"
	var ground := PlaneMesh.new()
	ground.size = Vector2(size_m, size_m)
	_add_mesh(root, "Ground", ground, Vector3.ZERO)
	_add_mesh(root, "Wall", _box(Vector3(20.0, 3.0, 1.0)), Vector3(0.0, 1.5, wall_face_z + 0.5))
	_write_gltf(root, pack_directory.path_join("tiles/a.glb"))
	var samples := roundi(size_m / step_m) + 1
	var heights := PackedFloat32Array()
	heights.resize(samples * samples)
	for row in samples:
		heights[row * samples + samples / 2] = ridge_height_m
	write_ground_heights(pack_directory, "a", heights)


static func write_slabs_tile(pack_directory: String, heights_m: Array, triangles: int) -> void:
	## One tile `a`, 20 m wide and centred on the origin, its ground at height 0, holding a
	## flat mesh of at least `triangles` triangles at each of `heights_m`, none of them ground.
	var corner := Vector2(-10.0, -10.0)
	write_tile_index(pack_directory, 20.0, 10.0, {"a": corner})
	write_flat_tile(pack_directory, "a", corner, 20.0, 0.0, "Ground", "")
	var root := Node3D.new()
	root.name = "Tile"
	for height_m in heights_m:
		var slab := PlaneMesh.new()
		slab.size = Vector2(20.0, 20.0)
		slab.subdivide_width = ceili(sqrt(triangles * 0.5))
		slab.subdivide_depth = slab.subdivide_width
		_add_mesh(root, "Slab_%d" % heights_m.find(height_m), slab, Vector3(0.0, height_m, 0.0))
	_write_gltf(root, pack_directory.path_join("tiles/a.glb"))


static func write_tile_row(
	pack_directory: String, tile_size_m: float, count: int, rise_m := 1.0
) -> void:
	## Tiles `t0`, `t1`, ... side by side along +X from the origin, each flat and `rise_m`
	## higher than the one before, its ground mesh named `Terrain_<key>`.
	var corners := {}
	for number in count:
		corners["t%d" % number] = Vector2(number * tile_size_m, -0.5 * tile_size_m)
	write_tile_index(pack_directory, tile_size_m, tile_size_m * 0.5, corners)
	for number in count:
		var key := "t%d" % number
		write_flat_tile(
			pack_directory, key, corners[key], tile_size_m, number * rise_m, "Terrain_" + key, ""
		)


static func write_ground_heights(
	pack_directory: String, key: String, heights_m: PackedFloat32Array
) -> void:
	## A tile's ground heights, rows running towards +Z and columns towards +X.
	var path := pack_directory.path_join("tiles").path_join(key + ".ground.f32")
	FileAccess.open(path, FileAccess.WRITE).store_buffer(heights_m.to_byte_array())


static func write_far_terrain(pack_directory: String, keys: Array) -> void:
	## far.glb with a mesh `Far_<key>` per key, and far.jpg.
	var root := Node3D.new()
	root.name = "Far"
	for key in keys:
		_add_mesh(root, "Far_" + key, PlaneMesh.new(), Vector3.ZERO)
	_write_gltf(root, pack_directory.path_join("far.glb"))
	var photo := Image.create_empty(4, 4, false, Image.FORMAT_RGB8)
	photo.fill(Color(0.3, 0.4, 0.2))
	photo.save_jpg(pack_directory.path_join("far.jpg"))


static func write_canopy(pack_directory: String, middles: Array) -> void:
	## canopy.glb with a flat mesh 2 m wide, `Canopy_<number>`, at each of `middles`.
	var root := Node3D.new()
	root.name = "Canopy"
	for number in middles.size():
		_add_mesh(root, "Canopy_%d" % number, PlaneMesh.new(), middles[number])
	_write_gltf(root, pack_directory.path_join("canopy.glb"))


static func write_tile_objects(pack_directory: String, key: String, standing: Dictionary) -> void:
	## A tile's `<key>.json`: `standing` with what it leaves out of trees, posts, plates and
	## signals listed empty.
	var listed := {"trees": {"conifer": [], "broadleaf": []}}
	for kind in ["posts", "plates", "signals"]:
		listed[kind] = []
	listed.merge(standing, true)
	var file := FileAccess.open(
		pack_directory.path_join("tiles").path_join(key + ".json"), FileAccess.WRITE
	)
	file.store_string(JSON.stringify(listed))


static func write_dds(pack_directory: String, file_name: String, colour: Color) -> void:
	## A 4 x 4 DDS texture of one colour.
	DirAccess.make_dir_recursive_absolute(pack_directory.path_join(file_name).get_base_dir())
	var image := Image.create_empty(4, 4, false, Image.FORMAT_RGB8)
	image.fill(colour)
	image.save_dds(pack_directory.path_join(file_name))


static func write_texture_set(pack_directory: String, textures: String) -> void:
	## The three maps of the texture set `textures`, each a few pixels of one colour.
	for suffix in SurfaceRule.TEXTURE_SUFFIXES:
		write_dds(pack_directory, textures + suffix, Color(0.5, 0.5, 0.5))


static func write_image(pack_directory: String, file_name: String, colour: Color) -> void:
	## A 4 x 4 PNG of one colour.
	DirAccess.make_dir_recursive_absolute(pack_directory.path_join(file_name).get_base_dir())
	var image := Image.create_empty(4, 4, false, Image.FORMAT_RGBA8)
	image.fill(colour)
	image.save_png(pack_directory.path_join(file_name))


static func ground_manifest(id: String) -> Dictionary:
	## A track manifest with one ground layer, a road and a terrain rule over the materials
	## named `M_Photo_*`; its files are written by `write_ground_files`.
	var manifest := track_manifest(id)
	manifest["track"]["ground"] = {
		"layers": [{"textures": "textures/grass", "size_m": 2.5, "photo": 0.6}],
		"slope_layer": 0,
		"photo_grade":
		{"black": [0.01, 0.02, 0.03], "gain": [0.3, 0.3, 0.3], "gamma": 0.7, "saturation": 1.3},
		"road": {"lines": "road_lines.png", "lap_length_m": 100.0, "layer": 0},
	}
	manifest["track"]["surfaces"] = [
		{"meshes": "Terrain_*", "materials": "M_Photo_*", "surface": "terrain"}
	]
	return manifest


static func write_ground_files(pack_directory: String) -> void:
	## What `ground_manifest` names, and the photo and surface map of the tile `a`.
	write_texture_set(pack_directory, "textures/grass")
	write_image(pack_directory, "road_lines.png", Color(0.4, 0.4, 0.5, 0.5))
	write_image(pack_directory, "tiles/a.surface.png", Color(0.0, 0.0, 0.0))
	var photo := Image.create_empty(4, 4, false, Image.FORMAT_RGB8)
	photo.fill(Color(0.4, 0.5, 0.3))
	photo.save_jpg(pack_directory.path_join("tiles/a.photo.jpg"))


static func _box(size: Vector3) -> BoxMesh:
	var box := BoxMesh.new()
	box.size = size
	return box


static func _add_mesh(parent: Node3D, node_name: String, mesh: Mesh, position: Vector3) -> void:
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = mesh
	instance.position = position
	parent.add_child(instance)
	instance.owner = parent


static func _write_gltf(root: Node3D, path: String) -> void:
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	document.append_from_scene(root, state)
	document.write_to_filesystem(state, path)
	root.free()


static func signs_manifest(id: String) -> Dictionary:
	## A valid track manifest with one sign face, a square of 0.6 m.
	var manifest := track_manifest(id)
	manifest["track"]["signs"] = {
		"faces":
		[
			{
				"id": "square",
				"image": "signs/square.png",
				"outline_m": [[-0.3, -0.3], [0.3, -0.3], [0.3, 0.3], [-0.3, 0.3]],
			}
		],
		"signal": {"lens_diameter_m": 0.2, "cycle_s": [18.0, 3.0, 23.0]},
	}
	return manifest


static func write_signs_files(pack_directory: String, placed: Dictionary) -> void:
	## The face's image `signs_manifest` names, and `placed` standing on the tile `a`.
	write_image(pack_directory, "signs/square.png", Color.RED)
	write_tile_objects(pack_directory, "a", placed)
