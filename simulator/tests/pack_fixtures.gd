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
	## A valid track manifest naming world.glb and a spawn at the origin.
	return {
		"format": 1,
		"kind": "track",
		"id": id,
		"name": "Test track",
		"version": "1.0.0",
		"licence": "CC0-1.0",
		"attribution": [],
		"track": {"world": "world.glb", "spawn": {"position_m": [0.0, 0.0, 0.0], "yaw_deg": 0.0}},
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
	## world.glb: a flat square of ground `size_m` wide, centred on the origin, at height 0.
	var root := Node3D.new()
	root.name = "World"
	var ground := PlaneMesh.new()
	ground.size = Vector2(size_m, size_m)
	_add_mesh(root, "Ground", ground, Vector3.ZERO)
	_write_gltf(root, pack_directory.path_join("world.glb"))


static func write_photo_world(pack_directory: String, material_name: String) -> void:
	## world.glb: a flat square of ground named `Terrain_a`, 20 m wide, drawn with a material
	## named `material_name` whose colour is a small image, as an orthophoto tile is.
	var root := Node3D.new()
	root.name = "World"
	var ground := PlaneMesh.new()
	ground.size = Vector2(20.0, 20.0)
	var material := StandardMaterial3D.new()
	material.resource_name = material_name
	var photo := Image.create_empty(4, 4, false, Image.FORMAT_RGB8)
	photo.fill(Color(0.4, 0.5, 0.3))
	material.albedo_texture = ImageTexture.create_from_image(photo)
	ground.material = material
	_add_mesh(root, "Terrain_a", ground, Vector3.ZERO)
	_write_gltf(root, pack_directory.path_join("world.glb"))


static func write_texture_set(pack_directory: String, textures: String) -> void:
	## The three maps of the texture set `textures`, each a few pixels of one colour.
	DirAccess.make_dir_recursive_absolute(pack_directory.path_join(textures).get_base_dir())
	for suffix in SurfaceRule.TEXTURE_SUFFIXES:
		var map := Image.create_empty(4, 4, false, Image.FORMAT_RGB8)
		map.fill(Color(0.5, 0.5, 0.5))
		map.save_jpg(pack_directory.path_join(textures + suffix))


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
		{
			"meshes": "Terrain_*",
			"materials": "M_Photo_*",
			"surface": "terrain",
			"map": "surfaces/*.png",
			"track_map": "track/*.png",
		}
	]
	return manifest


static func write_ground_files(pack_directory: String) -> void:
	## What `ground_manifest` names, for a world whose ground is drawn with `M_Photo_a`.
	write_texture_set(pack_directory, "textures/grass")
	write_image(pack_directory, "road_lines.png", Color(0.4, 0.4, 0.5, 0.5))
	write_image(pack_directory, "surfaces/a.png", Color(0.0, 0.0, 0.0))


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
		"placed": "signs.json",
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
	## The files `signs_manifest` names: the face's image, and `placed` as signs.json.
	DirAccess.make_dir_recursive_absolute(pack_directory.path_join("signs"))
	write_image(pack_directory, "signs/square.png", Color.RED)
	var file := FileAccess.open(pack_directory.path_join("signs.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(placed))
