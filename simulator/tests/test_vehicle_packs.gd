extends TestCase
## Vehicle packs: found by id on the search path, validated, built into a vehicle model.


func test_finds_a_vehicle_pack_by_id_on_the_search_path() -> void:
	var directory := PackFixtures.fresh_directory("finds_vehicle")
	PackFixtures.write_pack(directory, PackFixtures.vehicle_manifest("small_car"))
	var library := PackLibrary.scan([directory])

	var found := library.load_vehicle("small_car")

	assert_eq(library.errors, [] as Array[String])
	assert_true(found.has("vehicle"), str(found))
	var vehicle: VehicleSpec = found["vehicle"]
	assert_eq(vehicle.name, "Test vehicle")
	assert_almost_eq(vehicle.wheelbase_m(), 2.5)
	# ROS base_link (x forward, y left, z up) to Godot (+X left, +Y up, +Z forward)
	assert_almost_eq(vehicle.stereo.mount, Vector3(0.0, 1.16, 0.6))
	assert_almost_eq(vehicle.driver_eye, Vector3(0.38, 1.1, -0.2))


func test_names_the_pack_and_field_when_a_field_is_missing() -> void:
	var directory := PackFixtures.fresh_directory("missing_field")
	var manifest := PackFixtures.vehicle_manifest("small_car")
	manifest["vehicle"].erase("wheel_radius_m")
	PackFixtures.write_pack(directory, manifest)

	var found := PackLibrary.scan([directory]).load_vehicle("small_car")

	assert_eq(found, {"error": "small_car: vehicle.wheel_radius_m is missing or not a number"})


func test_reports_a_missing_pack() -> void:
	var library := PackLibrary.scan([PackFixtures.fresh_directory("empty")])

	assert_eq(library.load_vehicle("nowhere"), {"error": "no vehicle pack nowhere"})


func test_refuses_a_track_pack_as_a_vehicle() -> void:
	var directory := PackFixtures.fresh_directory("wrong_kind")
	PackFixtures.write_pack(directory, PackFixtures.track_manifest("ring"))

	var found := PackLibrary.scan([directory]).load_vehicle("ring")

	assert_eq(found, {"error": "no vehicle pack ring"})


func test_two_packs_with_one_id_are_an_error() -> void:
	var first := PackFixtures.fresh_directory("duplicate_a")
	var second := PackFixtures.fresh_directory("duplicate_b")
	PackFixtures.write_pack(first, PackFixtures.vehicle_manifest("small_car"))
	PackFixtures.write_pack(second, PackFixtures.vehicle_manifest("small_car"))

	var library := PackLibrary.scan([first, second])

	assert_eq(library.errors.size(), 1)
	assert_true(library.errors[0].begins_with("small_car: found twice"), library.errors[0])
	assert_eq(library.load_vehicle("small_car"), {"error": "no vehicle pack small_car"})


func test_reports_an_unreadable_manifest() -> void:
	var directory := PackFixtures.fresh_directory("unreadable")
	DirAccess.make_dir_recursive_absolute(directory.path_join("broken"))
	FileAccess.open(directory.path_join("broken/pack.json"), FileAccess.WRITE).store_string("{")

	var library := PackLibrary.scan([directory])

	assert_eq(library.errors.size(), 1)
	assert_true(library.errors[0].contains("broken"), library.errors[0])


func test_builds_a_box_and_cylinders_without_a_model() -> void:
	var directory := PackFixtures.fresh_directory("placeholder")
	PackFixtures.write_pack(directory, PackFixtures.vehicle_manifest("small_car"))
	var vehicle: VehicleSpec = PackLibrary.scan([directory]).load_vehicle("small_car")["vehicle"]

	var model: VehicleModel = VehicleModel.build(vehicle)["model"]

	assert_true(model.body is MeshInstance3D)
	assert_true(model.wheel is Node3D)
	assert_eq(model.cockpit_parts.size(), 0)
	model.free_all()


func test_builds_the_model_from_the_packs_gltf() -> void:
	var directory := PackFixtures.fresh_directory("model")
	var manifest := PackFixtures.vehicle_manifest("small_car")
	manifest["vehicle"]["model"] = "vehicle.glb"
	PackFixtures.write_vehicle_model(PackFixtures.write_pack(directory, manifest))
	var vehicle: VehicleSpec = PackLibrary.scan([directory]).load_vehicle("small_car")["vehicle"]

	var model: VehicleModel = VehicleModel.build(vehicle)["model"]

	assert_eq(String(model.body.name), "Body")
	assert_eq(String(model.wheel.name), "Wheel")
	assert_eq(model.cockpit_parts.map(func(part): return String(part.name)), ["Cockpit_Steer"])
	model.free_all()


func test_reports_a_model_without_a_body() -> void:
	var directory := PackFixtures.fresh_directory("no_body")
	var manifest := PackFixtures.vehicle_manifest("small_car")
	manifest["vehicle"]["model"] = "vehicle.glb"
	var pack_directory := PackFixtures.write_pack(directory, manifest)
	PackFixtures.write_flat_world(pack_directory, 4.0)
	DirAccess.rename_absolute(
		pack_directory.path_join("tiles/a.glb"), pack_directory.path_join("vehicle.glb")
	)
	var vehicle: VehicleSpec = PackLibrary.scan([directory]).load_vehicle("small_car")["vehicle"]

	assert_eq(VehicleModel.build(vehicle), {"error": "small_car: vehicle.glb has no Body node"})


func test_refuses_values_out_of_range() -> void:
	var cases := {
		"vehicle.wheel_radius_m": ["vehicle", "wheel_radius_m", 0.0],
		"vehicle.stereo.rate_hz": ["stereo", "rate_hz", 0.0],
		"vehicle.stereo.hfov_deg": ["stereo", "hfov_deg", 180.0],
		"vehicle.stereo.width_px": ["stereo", "width_px", 0],
		"vehicle.front_axle_x_m": ["vehicle", "front_axle_x_m", -2.0],
	}
	for field in cases:
		var directory := PackFixtures.fresh_directory("range")
		var manifest := PackFixtures.vehicle_manifest("small_car")
		var section: Dictionary = manifest["vehicle"]
		if cases[field][0] == "stereo":
			section = manifest["vehicle"]["stereo"]
		section[cases[field][1]] = cases[field][2]
		PackFixtures.write_pack(directory, manifest)

		var found := PackLibrary.scan([directory]).load_vehicle("small_car")

		assert_true(
			found.get("error", "").begins_with("small_car: %s is out of range" % field), str(found)
		)
