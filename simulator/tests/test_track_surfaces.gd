extends TestCase
## A track pack's ground, surfaces, trees and sun: read from pack.json and drawn in the world.


func test_reads_the_ground_and_its_surfaces() -> void:
	var track := _ground_track("reads_ground", PackFixtures.ground_manifest("ground"))

	assert_eq(track.ground.layers.size(), 1)
	assert_true(track.ground.layers[0].textures_path.ends_with("ground/textures/grass"))
	assert_almost_eq(track.ground.layers[0].size_m, 2.5)
	assert_almost_eq(track.ground.layers[0].photo, 0.6)
	assert_almost_eq(track.ground.photo_black, Vector3(0.01, 0.02, 0.03))
	assert_almost_eq(track.ground.photo_gamma, 0.7)
	assert_almost_eq(track.ground.lap_length_m, 100.0)
	assert_eq(track.surfaces.size(), 1)
	assert_eq(track.surfaces[0].kind, "terrain")


func test_a_rule_covers_the_meshes_and_materials_its_globs_match() -> void:
	var track := _ground_track("covers", PackFixtures.ground_manifest("ground"))
	var cases := {
		["Terrain_12", "M_Photo_12"]: true,
		["Road_3", "M_Photo_12"]: false,
		["Terrain_12", "M_Wall"]: false,
	}

	for names in cases:
		assert_eq(track.surface_rule(names[0], names[1]) != null, cases[names], str(names))


func test_a_map_is_named_after_what_the_material_glob_matched() -> void:
	var track := _ground_track("map_name", PackFixtures.ground_manifest("ground"))
	var rule := track.surface_rule("Terrain_x", "M_Photo_670012_610012")

	assert_true(rule.map_path("M_Photo_670012_610012").ends_with("surfaces/670012_610012.png"))
	assert_true(rule.track_map_path("M_Photo_670012_610012").ends_with("track/670012_610012.png"))


func test_the_first_rule_that_covers_a_material_draws_it() -> void:
	var manifest := PackFixtures.ground_manifest("ground")
	manifest["track"]["surfaces"].append(
		{"materials": "M_Photo_*", "surface": "roof", "textures": "textures/grass", "size_m": 3.0}
	)
	var track := _ground_track("first_rule", manifest)

	assert_eq(track.surface_rule("Terrain_1", "M_Photo_1").kind, "terrain")
	assert_eq(track.surface_rule("Building_1", "M_Photo_1").kind, "roof")


func test_refuses_what_a_pack_gets_wrong() -> void:
	var cases := {
		"ground: track.surfaces[0].surface is not one of terrain, roof, facade, plain, seats":
		func(track): track["surfaces"][0]["surface"] = "water",
		(
			"ground: track.ground.layers[0].textures names textures/moss_albedo.jpg,"
			+ " which is not in the pack"
		):
		func(track): track["ground"]["layers"][0]["textures"] = "textures/moss",
		"ground: track.ground.layers[0].photo is out of range":
		func(track): track["ground"]["layers"][0]["photo"] = 1.5,
		"ground: track.ground.photo_grade.gain is missing or not a list of 3 numbers":
		func(track): track["ground"]["photo_grade"].erase("gain"),
		"ground: track.ground.road.lines names lines.png, which is not in the pack":
		func(track): track["ground"]["road"]["lines"] = "lines.png",
		"ground: track.surfaces needs track.ground for its terrain":
		func(track): track.erase("ground"),
		"ground: track.surfaces needs track.ground.road for its track_map":
		func(track): track["ground"].erase("road"),
		"ground: track.surfaces[1].windows is not one of house, hall, office":
		func(track): _add_facade_with_shop_windows(track),
		"ground: track.sun.elevation_deg is out of range":
		func(track): track["sun"] = {"azimuth_deg": 10.0, "elevation_deg": 95.0},
		"ground: track.trees.instances names trees.json, which is not in the pack":
		func(track): track["trees"] = {"instances": "trees.json", "impostors": []},
	}
	for reason in cases:
		var manifest := PackFixtures.ground_manifest("ground")
		cases[reason].call(manifest["track"])
		var directory := PackFixtures.fresh_directory("refuses")
		PackFixtures.write_ground_files(PackFixtures.write_pack(directory, manifest))

		assert_eq(PackLibrary.scan([directory]).load_track("ground"), {"error": reason})


func test_reads_the_roads_and_parking_lots_on_the_ground() -> void:
	var track := _ground_track("reads_lots", _manifest_with_roads_and_lots())

	assert_true(track.ground.roads_lines_path.ends_with("roads_lines.png"))
	assert_eq(track.ground.road_dashes, [Vector2(2.5, 10.0), Vector2(1.25, 1.25)] as Array[Vector2])
	assert_almost_eq(track.ground.road_line_width_m, 0.15)
	assert_eq(track.ground.lots.size(), 1)
	var lot := track.ground.lots[0]
	assert_eq(lot.layer, 0)
	assert_almost_eq(lot.colour, Vector3(0.2, 0.21, 0.22))
	# The pack's x (ROS forward) is Godot's z, its y Godot's x; yaw 90° runs along its y.
	assert_almost_eq(lot.origin, Vector2(20.0, -15.0))
	assert_almost_eq(lot.along, Vector2(1.0, 0.0), 1e-6)
	assert_almost_eq(lot.across, Vector2(0.0, -1.0), 1e-6)
	assert_almost_eq(lot.bay_width_m, 2.5)
	assert_almost_eq(lot.rows[0].along_m, Vector2(-10.0, 15.0))
	assert_almost_eq(lot.rows[0].across_m, Vector2(2.0, 7.0))
	assert_almost_eq(lot.rows[0].ends, Vector2(1.0, 0.0))
	var rule := track.surface_rule("Terrain_x", "M_Photo_a")
	assert_true(rule.roads_map_path("M_Photo_a").ends_with("roads/a.png"))
	assert_true(rule.lots_map_path("M_Photo_a").ends_with("lots/a.png"))


func test_refuses_roads_and_lots_a_pack_gets_wrong() -> void:
	var cases := {
		"ground: track.surfaces needs track.ground.roads for its roads_map":
		func(track, _lots): track["ground"].erase("roads"),
		"ground: track.ground.roads.lines names lines.png, which is not in the pack":
		func(track, _lots): track["ground"]["roads"]["lines"] = "lines.png",
		"ground: track.ground.roads.dashes_m.0 is missing or not a list of 2 numbers":
		func(track, _lots): track["ground"]["roads"]["dashes_m"][0] = [2.5],
		"ground: track.ground.lots names parking.json, which is not in the pack":
		func(track, _lots): track["ground"]["lots"] = "parking.json",
		"ground: lots.json: lots[0].layer is out of range":
		func(_track, lots): lots[0]["layer"] = 4,
		"ground: lots.json: lots[0].origin_m is missing or not a list of 2 numbers":
		func(_track, lots): lots[0].erase("origin_m"),
		"ground: lots.json: lots[0].rows[0].ends is missing or not a list of 2 numbers":
		func(_track, lots): lots[0]["rows"][0]["ends"] = [1],
		"ground: lots.json: lots[0].bay_width_m is out of range":
		func(_track, lots): lots[0]["bay_width_m"] = 0.0,
		"ground: lots.json: lots is missing or not a list of objects":
		func(_track, lots): lots[0] = 3,
	}
	for reason in cases:
		var manifest := _manifest_with_roads_and_lots()
		var lots := _lots()
		cases[reason].call(manifest["track"], lots)
		var directory := PackFixtures.fresh_directory("refuses_lots")
		var pack_directory := PackFixtures.write_pack(directory, manifest)
		PackFixtures.write_ground_files(pack_directory)
		_write_roads_and_lots(pack_directory, lots)

		assert_eq(PackLibrary.scan([directory]).load_track("ground"), {"error": reason})


func test_draws_the_roads_and_lots_with_the_terrain_surface() -> void:
	var track := _ground_track("draws_lots", _manifest_with_roads_and_lots())

	var loaded := TrackWorld.load_world(track)

	var ground: MeshInstance3D = loaded["world"].find_child("Terrain_a")
	var material := ground.get_surface_override_material(0) as ShaderMaterial
	assert_true(material.get_shader_parameter("roads_lines") is Texture2D)
	assert_eq(
		material.get_shader_parameter("road_dashes"),
		PackedVector2Array([Vector2(2.5, 10.0), Vector2(1.25, 1.25)])
	)
	assert_eq((material.get_shader_parameter("roads_map") as Texture2D).get_size(), Vector2(4, 4))
	assert_eq((material.get_shader_parameter("lots_map") as Texture2D).get_size(), Vector2(1, 1))
	assert_eq(material.get_shader_parameter("layer_joints_m"), PackedFloat32Array([5.0]))
	loaded["world"].free()


func test_a_lot_is_a_row_of_texels_for_the_shader() -> void:
	var track := _ground_track("lot_texels", _manifest_with_roads_and_lots())

	var texels := SurfaceMaterials.lots_texture(track.ground.lots).get_image()

	assert_eq(texels.get_height(), 1)
	assert_almost_eq(texels.get_pixel(0, 0), Color(20.0, -15.0, 1.0, 0.0), 1e-5)
	assert_almost_eq(texels.get_pixel(1, 0), Color(0.2, 0.21, 0.22, 0.0), 1e-5)
	assert_almost_eq(texels.get_pixel(2, 0), Color(2.5, 1.0, 0.0, 0.0), 1e-5)
	assert_almost_eq(texels.get_pixel(3, 0), Color(-10.0, 15.0, 2.0, 7.0), 1e-5)
	assert_almost_eq(texels.get_pixel(4, 0), Color(1.0, 0.0, 0.0, 0.0), 1e-5)


func test_the_sun_is_where_the_pack_puts_it() -> void:
	var manifest := PackFixtures.track_manifest("flat")
	# ROS azimuth 90° is towards +y: Godot +X.
	manifest["track"]["sun"] = {"azimuth_deg": 90.0, "elevation_deg": 30.0}
	var track := _ground_track("sun", manifest)

	var sun: DirectionalLight3D = TrackWorld.lighting(track)["sun"]

	assert_almost_eq(track.sun_direction(), Vector3(cos(PI / 6.0), 0.5, 0.0), 1e-6)
	assert_almost_eq(sun.basis.z, track.sun_direction(), 1e-5)


func test_draws_the_ground_with_the_terrain_surface() -> void:
	var track := _ground_track("draws", PackFixtures.ground_manifest("ground"))

	var loaded := TrackWorld.load_world(track)

	var ground: MeshInstance3D = loaded["world"].find_child("Terrain_a")
	var material := ground.get_surface_override_material(0) as ShaderMaterial
	assert_true(material != null, "the ground keeps its glTF material")
	assert_eq(material.shader.resource_path, "res://world/shaders/terrain.gdshader")
	assert_almost_eq(material.get_shader_parameter("photo_gamma"), 0.7)
	assert_almost_eq(material.get_shader_parameter("lap_length_m"), 100.0)
	assert_eq(material.get_shader_parameter("layer_size_m"), PackedFloat32Array([2.5]))
	assert_true(material.get_shader_parameter("photo") is Texture2D)
	loaded["world"].free()


func test_a_material_no_rule_covers_keeps_its_gltf_definition() -> void:
	var manifest := PackFixtures.ground_manifest("ground")
	manifest["track"]["surfaces"][0]["materials"] = "M_Other_*"
	var track := _ground_track("keeps", manifest)

	var loaded := TrackWorld.load_world(track)

	var ground: MeshInstance3D = loaded["world"].find_child("Terrain_a")
	assert_true(ground.get_surface_override_material(0) == null, "the ground's material changed")
	loaded["world"].free()


func test_reports_a_surface_map_that_is_not_there() -> void:
	var manifest := PackFixtures.ground_manifest("ground")
	manifest["track"]["surfaces"][0]["map"] = "maps/*.png"
	var track := _ground_track("no_map", manifest)

	assert_eq(
		TrackWorld.load_world(track), {"error": "ground: the surface map a.png is not in the pack"}
	)


func test_plants_the_trees_of_the_pack() -> void:
	var manifest := PackFixtures.track_manifest("flat")
	manifest["track"]["trees"] = {
		"instances": "trees.json",
		"impostors":
		[{"atlas": "fir.png", "views": 3, "width_m": 6.0, "height_m": 18.0, "kind": "conifer"}],
	}
	var directory := PackFixtures.fresh_directory("trees")
	var pack_directory := PackFixtures.write_pack(directory, manifest)
	PackFixtures.write_flat_world(pack_directory, 20.0)
	PackFixtures.write_image(pack_directory, "fir.png", Color.GREEN)
	var standing := {"conifer": [[5.0, 2.0, 1.0, 12.0], [6.0, -3.0, 0.5, 20.0]], "broadleaf": []}
	var file := FileAccess.open(pack_directory.path_join("trees.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(standing))
	file.close()
	var track: TrackSpec = PackLibrary.scan([directory]).load_track("flat")["track"]

	var loaded := TrackWorld.load_world(track)

	var batch: MultiMeshInstance3D = loaded["world"].get_node("Forest").get_child(0)
	assert_eq(batch.multimesh.instance_count, 2)
	assert_almost_eq(Forest.standing_at(standing["conifer"][0]), Vector3(2.0, 1.0, 5.0))
	loaded["world"].free()


func test_finds_the_sun_in_a_panorama() -> void:
	var panorama := Image.create_empty(64, 32, false, Image.FORMAT_RGBF)
	panorama.fill(Color(0.2, 0.3, 0.5))
	# Three quarters across is a quarter turn right of the panorama's centre; 8 rows of 32
	# down is 45° above the horizon.
	panorama.fill_rect(Rect2i(47, 7, 2, 2), Color(500.0, 500.0, 450.0))

	var towards_sun := SkySun.direction(panorama)

	assert_almost_eq(towards_sun, Vector3(sqrt(0.5), sqrt(0.5), 0.0), 0.05)


func test_a_sky_is_turned_so_its_sun_is_where_the_light_comes_from() -> void:
	var manifest := PackFixtures.track_manifest("flat")
	manifest["track"]["sky"] = "sky.png"
	manifest["track"]["sun"] = {"azimuth_deg": 0.0, "elevation_deg": 45.0}
	var directory := PackFixtures.fresh_directory("sky_turn")
	var pack_directory := PackFixtures.write_pack(directory, manifest)
	var panorama := Image.create_empty(64, 32, false, Image.FORMAT_RGB8)
	panorama.fill(Color(0.1, 0.1, 0.2))
	panorama.fill_rect(Rect2i(47, 7, 2, 2), Color.WHITE)  # the sun towards +X
	panorama.save_png(pack_directory.path_join("sky.png"))
	var track: TrackSpec = PackLibrary.scan([directory]).load_track("flat")["track"]

	var environment: Environment = TrackWorld.lighting(track)["environment"]

	# From +X to +Z (ROS azimuth 0) is a quarter turn back about +Y.
	assert_almost_eq(environment.sky_rotation.y, -PI / 2.0, 0.05)


func _ground_track(test_name: String, manifest: Dictionary) -> TrackSpec:
	var directory := PackFixtures.fresh_directory(test_name)
	var pack_directory := PackFixtures.write_pack(directory, manifest)
	PackFixtures.write_photo_world(pack_directory, "M_Photo_a")
	PackFixtures.write_ground_files(pack_directory)
	if manifest["track"].get("ground", {}).has("roads"):
		_write_roads_and_lots(pack_directory, _lots())
	var found := PackLibrary.scan([directory]).load_track(manifest["id"])
	if found.has("error"):
		fail(found["error"])
	return found["track"]


func _manifest_with_roads_and_lots() -> Dictionary:
	## The ground manifest with slabs, roads around the lap (on tile a) and a parking lot (on
	## no tile).
	var manifest := PackFixtures.ground_manifest("ground")
	var ground: Dictionary = manifest["track"]["ground"]
	ground["layers"][0]["joints_m"] = 5.0
	ground["roads"] = {
		"lines": "roads_lines.png", "dashes_m": [[2.5, 10.0], [1.25, 1.25]], "line_width_m": 0.15
	}
	ground["lots"] = "lots.json"
	manifest["track"]["surfaces"][0]["roads_map"] = "roads/*.png"
	manifest["track"]["surfaces"][0]["lots_map"] = "lots/*.png"
	return manifest


func _lots() -> Array:
	return [
		{
			"layer": 0,
			"colour": [0.2, 0.21, 0.22],
			"origin_m": [-15.0, 20.0],
			"yaw_deg": 90.0,
			"bay_width_m": 2.5,
			"rows": [{"along_m": [-10.0, 15.0], "across_m": [2.0, 7.0], "ends": [1, 0]}],
		}
	]


func _write_roads_and_lots(pack_directory: String, lots: Array) -> void:
	PackFixtures.write_image(pack_directory, "roads_lines.png", Color(0.2, 0.2, 0.0, 1.0))
	PackFixtures.write_image(pack_directory, "roads/a.png", Color(0.0, 0.0, 0.5, 0.5))
	var file := FileAccess.open(pack_directory.path_join("lots.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(lots))
	file.close()


func _add_facade_with_shop_windows(track: Dictionary) -> void:
	var facade := {
		"materials": "M_Wall",
		"surface": "facade",
		"textures": "textures/grass",
		"size_m": 2.0,
		"windows": "shop",
		"tint": [1, 1, 1],
	}
	track["surfaces"].append(facade)
