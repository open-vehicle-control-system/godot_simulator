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


func test_a_stereo_pair_without_camera_fields_is_a_pinhole_with_no_effect() -> void:
	var stereo := _stereo_with({})

	assert_true(stereo.distortion == null)
	assert_true(not stereo.looks_like_a_camera())
	assert_eq(stereo.overscan(), 1.0)


func test_reads_what_makes_the_stereo_pair_look_like_cameras() -> void:
	var stereo := _stereo_with(
		{
			"distortion": {"k1": -0.2, "k2": 0.03, "p1": 0.001, "p2": -0.002, "k3": 0.004},
			"vignetting": 0.35,
			"noise": {"read": 0.003, "shot": 0.012},
			"exposure": {"target": 0.12, "speed_per_s": 2.0, "max_stops": 3.0},
			"motion_blur": {"shutter_s": 0.008},
		}
	)

	assert_eq(stereo.distortion.coefficients(), [-0.2, 0.03, 0.001, -0.002, 0.004])
	assert_eq(stereo.vignetting, 0.35)
	assert_eq([stereo.read_noise, stereo.shot_noise], [0.003, 0.012])
	assert_eq(stereo.exposure_target, 0.12)
	assert_eq(stereo.exposure_speed_per_s, 2.0)
	assert_eq(stereo.exposure_max_stops, 3.0)
	assert_eq(stereo.shutter_s, 0.008)
	assert_true(stereo.looks_like_a_camera())
	assert_true(stereo.overscan() > 1.1, "a barrel lens sees wider than its image's pinhole")


func test_each_camera_effect_is_on_by_its_own() -> void:
	for effect: Dictionary in [
		{"vignetting": 0.2},
		{"noise": {"read": 0.0, "shot": 0.01}},
		{"exposure": {"target": 0.1, "speed_per_s": 1.0, "max_stops": 2.0}},
		{"motion_blur": {"shutter_s": 0.01}},
		{"distortion": {"k1": 0.05, "k2": 0.0, "p1": 0.0, "p2": 0.0, "k3": 0.0}},
	]:
		assert_true(_stereo_with(effect).looks_like_a_camera(), str(effect))


func test_refuses_camera_effects_out_of_range() -> void:
	var cases := {
		"vehicle.stereo.vignetting": {"vignetting": 1.5},
		"vehicle.stereo.noise.read": {"noise": {"read": -0.1, "shot": 0.01}},
		"vehicle.stereo.exposure.target":
		{"exposure": {"target": 0.0, "speed_per_s": 1.0, "max_stops": 2.0}},
		"vehicle.stereo.motion_blur.shutter_s": {"motion_blur": {"shutter_s": 0.0}},
		# A lens that shows a point twice within the image.
		"vehicle.stereo.distortion":
		{"distortion": {"k1": -0.9, "k2": 0.0, "p1": 0.0, "p2": 0.0, "k3": 0.0}},
	}
	for field in cases:
		var found := _vehicle_with_stereo(cases[field])
		assert_eq(found, {"error": "small_car: %s is out of range" % field})


func _stereo_with(camera_fields: Dictionary) -> VehicleSpec.StereoOptics:
	var found := _vehicle_with_stereo(camera_fields)
	assert_true(found.has("vehicle"), str(found))
	return found["vehicle"].stereo


func _vehicle_with_stereo(camera_fields: Dictionary) -> Dictionary:
	var directory := PackFixtures.fresh_directory("camera_fields")
	var manifest := PackFixtures.vehicle_manifest("small_car")
	manifest["vehicle"]["stereo"].merge(camera_fields)
	PackFixtures.write_pack(directory, manifest)
	return PackLibrary.scan([directory]).load_vehicle("small_car")


func test_refuses_dynamics_out_of_range() -> void:
	var cases := {
		"mass_kg": 0.0,
		"centre_of_gravity_x_m": 1.5,
		"yaw_inertia_kg_m2": -1.0,
		"brake_bias_front": 1.2,
		"rear_brake_margin": 1.0,
		"front_roll_stiffness_share": 1.0,
		"friction": 0.0,
		"rear_cornering_stiffness_n_per_rad": 0.0,
		"cornering_stiffness_load_exponent": 1.5,
		"friction_load_sensitivity": -0.1,
		"tyre_shape": 1.0,
		"tyre_curvature": 1.0,
	}
	for field in cases:
		var found := _vehicle_with_dynamics(field, cases[field])

		assert_eq(found, {"error": "small_car: vehicle.dynamics.%s is out of range" % field}, field)
	assert_eq(
		_vehicle_with_dynamics("driven_axle", "middle"),
		{"error": "small_car: vehicle.dynamics.driven_axle is not one of front, rear, all"}
	)


func _vehicle_with_dynamics(field: String, value: Variant) -> Dictionary:
	var directory := PackFixtures.fresh_directory("dynamics_" + field)
	var manifest := PackFixtures.vehicle_manifest("small_car")
	manifest["vehicle"]["dynamics"][field] = value
	PackFixtures.write_pack(directory, manifest)
	return PackLibrary.scan([directory]).load_vehicle("small_car")


func test_settings_override_the_pack_before_it_is_checked() -> void:
	var directory := PackFixtures.fresh_directory("settings")
	PackFixtures.write_pack(directory, PackFixtures.vehicle_manifest("small_car"))
	var library := PackLibrary.scan([directory])
	var settings := [
		["vehicle.dynamics.brake_bias_front", 0.55],
		["track.sun.azimuth_deg", 10.0],
		["vehicle.dynamics.rear_cornering_stiffness_n_per_rad", 90000.0],
	]

	var found := library.load_vehicle("small_car", settings)

	var spec: VehicleSpec = found["vehicle"]
	assert_almost_eq(spec.brake_bias_front, 0.55, 1e-9)
	assert_almost_eq(spec.rear_cornering_stiffness_n_per_rad, 90000.0, 1e-9)
	var again: VehicleSpec = library.load_vehicle("small_car")["vehicle"]
	assert_almost_eq(again.brake_bias_front, 0.7, 1e-9, "the pack itself is unchanged")


func test_settings_are_checked_as_the_pack_is() -> void:
	var directory := PackFixtures.fresh_directory("settings_checked")
	PackFixtures.write_pack(directory, PackFixtures.vehicle_manifest("small_car"))
	var library := PackLibrary.scan([directory])
	var cases := {
		"small_car: vehicle.dynamics.brake_bias_front is out of range":
		["vehicle.dynamics.brake_bias_front", 1.5],
		"small_car: --set vehicle.dynamics.brake_bias: the pack has no such field":
		["vehicle.dynamics.brake_bias", 0.6],
		"small_car: --set vehicle.dynamics.friction.peak: the pack has no such field":
		["vehicle.dynamics.friction.peak", 0.6],
	}
	for problem in cases:
		assert_eq(library.load_vehicle("small_car", [cases[problem]]), {"error": problem})
