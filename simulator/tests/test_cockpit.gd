extends TestCase
## The cockpit a vehicle pack describes: needles and steering wheel that follow the vehicle,
## mirrors that show what is behind.


func test_reads_the_instruments_and_mirrors_in_godots_frame() -> void:
	var spec := _spec("reads_cockpit", PackFixtures.cockpit_manifest("small_car"))

	# ROS x forward is Godot +Z.
	assert_almost_eq(spec.instruments.speedometer.axis, Vector3.BACK)
	assert_eq(spec.instruments.speedometer.node, "Cockpit_Speed")
	assert_eq(
		spec.instruments.speedometer.dial,
		[Vector2(0.0, 0.0), Vector2(100.0, 120.0), Vector2(200.0, 200.0)] as Array[Vector2]
	)
	assert_almost_eq(spec.instruments.rev_counter.max_rpm, 6000.0)
	assert_almost_eq(spec.instruments.steering_wheel.axis, Vector3.FORWARD)
	assert_eq(spec.mirrors.material, "Mirror_Glass")
	assert_almost_eq(spec.mirrors.door_hfov_deg, 30.0)


func test_a_pack_without_them_has_no_instruments_or_mirrors() -> void:
	var spec := _spec("no_cockpit", PackFixtures.vehicle_manifest("small_car"))

	assert_eq(spec.instruments, null)
	assert_eq(spec.mirrors, null)


func test_a_pack_may_have_only_some_instruments() -> void:
	var manifest := PackFixtures.cockpit_manifest("small_car")
	manifest["vehicle"]["instruments"].erase("rev_counter")

	var spec := _spec("some_instruments", manifest)

	assert_eq(spec.instruments.rev_counter, null)
	assert_true(spec.instruments.speedometer != null)


func test_refuses_instruments_and_mirrors_out_of_range() -> void:
	var cases := {
		"vehicle.instruments.speedometer.axis": ["speedometer", "axis", [0.0, 0.0, 0.0]],
		"vehicle.instruments.speedometer.km_h_to_deg": ["speedometer", "km_h_to_deg", [[0, 0.0]]],
		"vehicle.instruments.speedometer.km_h_to_deg.1":
		["speedometer", "km_h_to_deg", [[50, 0.0], [50, 90.0]]],
		"vehicle.instruments.rev_counter.max_rpm": ["rev_counter", "max_rpm", 0],
		"vehicle.instruments.rev_counter.deg_per_rpm": ["rev_counter", "deg_per_rpm", -0.05],
		"vehicle.instruments.steering_wheel.ratio": ["steering_wheel", "ratio", 0.0],
		"vehicle.mirrors.door_hfov_deg": ["mirrors", "door_hfov_deg", 180.0],
	}
	for field in cases:
		var manifest := PackFixtures.cockpit_manifest("small_car")
		var section: Dictionary = manifest["vehicle"]
		if cases[field][0] != "mirrors":
			section = section["instruments"]
		section[cases[field][0]][cases[field][1]] = cases[field][2]
		var directory := PackFixtures.fresh_directory("cockpit_range")
		PackFixtures.write_pack(directory, manifest)

		var found := PackLibrary.scan([directory]).load_vehicle("small_car")

		assert_eq(found, {"error": "small_car: %s is out of range" % field})


func test_names_a_missing_instrument_field() -> void:
	var manifest := PackFixtures.cockpit_manifest("small_car")
	manifest["vehicle"]["instruments"]["steering_wheel"].erase("lock_deg")
	var directory := PackFixtures.fresh_directory("cockpit_missing")
	PackFixtures.write_pack(directory, manifest)

	var found := PackLibrary.scan([directory]).load_vehicle("small_car")

	assert_eq(
		found,
		{
			"error":
			"small_car: vehicle.instruments.steering_wheel.lock_deg is missing or not a number"
		}
	)


func test_needles_and_steering_wheel_follow_the_vehicle() -> void:
	var cockpit := await _cockpit_on_flat_track("needles", {}, func(): return 3000.0)
	var vehicle: Vehicle = cockpit["vehicle"]
	var parts: Dictionary = cockpit["parts"]
	var rest: Basis = parts["Cockpit_Speed"].basis

	# 20 m/s is 72 km/h.
	vehicle.command(20.0, deg_to_rad(5.0))
	await _physics_then_process_frames()

	assert_almost_eq(
		parts["Cockpit_Speed"].basis.x, Basis(Vector3.BACK, deg_to_rad(72.0 * 1.2)) * rest.x, 1e-4
	)
	assert_almost_eq(
		parts["Cockpit_Revs"].basis.x, Basis(Vector3.BACK, deg_to_rad(3000.0 * 0.05)) * rest.x, 1e-4
	)
	# Steering left turns the wheel anticlockwise seen from the seat: about the axis towards
	# the driver.
	assert_almost_eq(
		parts["Cockpit_Steer"].basis.x, Basis(Vector3.FORWARD, deg_to_rad(80.0)) * rest.x, 1e-4
	)
	# Each turns about its own pivot.
	assert_almost_eq(parts["Cockpit_Speed"].position, Vector3(0.38, 0.9, 0.3), 1e-5)


func test_rev_counter_shows_the_reported_rpm_whichever_way_the_motor_turns() -> void:
	var cockpit := await _cockpit_on_flat_track("reverse_rpm", {}, func(): return -1000.0)
	var needle: Node3D = cockpit["parts"]["Cockpit_Revs"]
	# The rev counter has turned already; the speedometer at standstill rests as it does.
	var rest: Basis = cockpit["parts"]["Cockpit_Speed"].basis

	await _physics_then_process_frames()

	assert_almost_eq(needle.basis.x, Basis(Vector3.BACK, deg_to_rad(1000.0 * 0.05)) * rest.x, 1e-4)


func test_rev_counter_rests_without_a_reported_rpm_however_fast_the_vehicle_goes() -> void:
	var cockpit := await _cockpit_on_flat_track("no_rpm")
	var needle: Node3D = cockpit["parts"]["Cockpit_Revs"]
	var rest := needle.basis

	cockpit["vehicle"].command(20.0, 0.0)
	await _physics_then_process_frames()

	assert_almost_eq(needle.basis.x, rest.x, 1e-6)


func test_speedometer_shows_the_speed_when_reversing() -> void:
	var cockpit := await _cockpit_on_flat_track("reversing")
	var needle: Node3D = cockpit["parts"]["Cockpit_Speed"]
	var rest := needle.basis

	cockpit["vehicle"].command(-5.0, 0.0)
	await _physics_then_process_frames()

	assert_almost_eq(needle.basis.x, Basis(Vector3.BACK, deg_to_rad(18.0 * 1.2)) * rest.x, 1e-4)


func test_reports_an_instrument_whose_node_the_model_lacks() -> void:
	var manifest := PackFixtures.cockpit_manifest("small_car")
	manifest["vehicle"]["instruments"]["rev_counter"]["node"] = "Cockpit_Tacho"
	var spec := _spec("lacking_node", manifest)
	var model: VehicleModel = VehicleModel.build(spec)["model"]
	var vehicle := Vehicle.new()
	add_child(vehicle)
	vehicle.setup(spec, model)
	var instruments := Instruments.new()
	add_child(instruments)

	var problem := instruments.setup(vehicle, model.cockpit_parts)

	assert_eq(
		problem,
		(
			"small_car: vehicle.instruments.rev_counter.node names Cockpit_Tacho,"
			+ " which is not a cockpit part of the model"
		)
	)
	instruments.queue_free()
	vehicle.queue_free()


func test_finds_each_mirrors_glass_by_its_side_of_the_vehicle() -> void:
	var vertices := PackedVector3Array(
		[
			Vector3(0.8, 1.0, 0.5),
			Vector3(1.0, 1.1, 0.6),
			Vector3(-0.1, 1.3, 0.4),
			Vector3(0.1, 1.36, 0.4),
			Vector3(-1.0, 1.0, 0.5),
			Vector3(-0.8, 1.1, 0.6),
		]
	)

	var boxes := Mirrors.glass_boxes(vertices, 0.4)

	assert_eq(boxes.keys(), ["left", "interior", "right"])
	assert_almost_eq(boxes["left"].get_center(), Vector3(0.9, 1.05, 0.55), 1e-5)
	assert_almost_eq(boxes["interior"].size, Vector3(0.2, 0.06, 0.0), 1e-5)
	assert_almost_eq(boxes["right"].get_center(), Vector3(-0.9, 1.05, 0.55), 1e-5)


func test_each_mirror_looks_back_from_its_glass() -> void:
	var cockpit := await _cockpit_on_flat_track("mirrors")
	var vehicle: Vehicle = cockpit["vehicle"]
	var mirrors: Mirrors = cockpit["mirrors"]

	vehicle.global_transform = Transform3D(Basis(Vector3.UP, PI / 2.0), Vector3(5.0, 0.0, 0.0))
	await _physics_then_process_frames()

	# Left door, interior, right door: the fixture's glass, on a body 0.85 m up.
	var glass_centres := [
		Vector3(0.9, 1.05, 0.5), Vector3(0.0, 1.25, 0.4), Vector3(-0.9, 1.05, 0.5)
	]
	assert_eq(mirrors.cameras.size(), 3)
	for index in 3:
		var camera := mirrors.cameras[index]
		assert_almost_eq(
			camera.global_position, vehicle.global_transform * glass_centres[index], 1e-4
		)
		assert_almost_eq(-camera.global_basis.z, -vehicle.global_basis.z, 1e-4, "looking back")
	assert_almost_eq(mirrors.cameras[0].fov, 30.0)
	assert_almost_eq(mirrors.cameras[1].fov, 45.0)
	# Glass 0.2 m wide and 0.1 m high.
	assert_eq(mirrors.viewports[0].size, Vector2i(Mirrors.VIEW_WIDTH_PX, Mirrors.VIEW_WIDTH_PX / 2))


func test_mirrors_render_only_while_live() -> void:
	var cockpit := await _cockpit_on_flat_track("live_mirrors")
	var mirrors: Mirrors = cockpit["mirrors"]

	var modes_at_rest := mirrors.viewports.map(_update_mode)
	mirrors.live = true
	var modes_live := mirrors.viewports.map(_update_mode)
	mirrors.live = false

	var disabled := SubViewport.UPDATE_DISABLED
	var always := SubViewport.UPDATE_ALWAYS
	assert_eq(modes_at_rest, [disabled, disabled, disabled])
	assert_eq(modes_live, [always, always, always])
	assert_eq(mirrors.viewports.map(_update_mode), [disabled, disabled, disabled])


func test_reports_mirrors_whose_material_the_body_lacks() -> void:
	var manifest := PackFixtures.cockpit_manifest("small_car")
	manifest["vehicle"]["mirrors"]["material"] = "Chrome"
	var spec := _spec("lacking_glass", manifest)
	var model: VehicleModel = VehicleModel.build(spec)["model"]
	var mirrors := Mirrors.new()
	add_child(mirrors)

	var problem := mirrors.setup(spec, model.body, null)

	assert_eq(
		problem,
		"small_car: vehicle.mirrors.material names Chrome, which the model's Body is not drawn with"
	)
	mirrors.queue_free()
	model.free_all()


func _physics_then_process_frames() -> void:
	## Lets the vehicle move, then every node process: `process_frame` comes before the
	## nodes' own processing, so the second one follows it.
	await wait_physics_frames(2)
	await get_tree().process_frame
	await get_tree().process_frame


func _update_mode(viewport: SubViewport) -> SubViewport.UpdateMode:
	return viewport.render_target_update_mode


func _spec(test_name: String, manifest: Dictionary) -> VehicleSpec:
	var directory := PackFixtures.fresh_directory(test_name)
	PackFixtures.write_cockpit_model(PackFixtures.write_pack(directory, manifest))
	var found := PackLibrary.scan([directory]).load_vehicle(manifest["id"])
	assert_true(found.has("vehicle"), str(found))
	return found["vehicle"]


func _cockpit_on_flat_track(
	test_name: String, manifest := {}, reported_motor_rpm := Callable()
) -> Dictionary:
	## `{"vehicle", "parts", "mirrors"}`: the cockpit fixture's vehicle (or `manifest`'s) on flat
	## ground, its cockpit parts by name and its mirrors; its rev counter shows
	## `reported_motor_rpm`'s rpm, if given.
	var directory := PackFixtures.fresh_directory(test_name + "_track")
	var track_directory := PackFixtures.write_pack(directory, PackFixtures.track_manifest("flat"))
	PackFixtures.write_flat_world(track_directory, 400.0)
	var track: TrackSpec = PackLibrary.scan([directory]).load_track("flat")["track"]
	add_child(TrackWorld.load_world(track)["world"])
	if manifest.is_empty():
		manifest = PackFixtures.cockpit_manifest("small_car")
	var spec := _spec(test_name, manifest)
	var model: VehicleModel = VehicleModel.build(spec)["model"]
	var vehicle := Vehicle.new()
	add_child(vehicle)
	vehicle.setup(spec, model)
	var instruments := Instruments.new()
	add_child(instruments)
	assert_eq(instruments.setup(vehicle, model.cockpit_parts, reported_motor_rpm), "")
	var mirrors := Mirrors.new()
	add_child(mirrors)
	assert_eq(mirrors.setup(spec, model.body, null), "")
	var parts := {}
	for part in model.cockpit_parts:
		parts[String(part.name)] = part
	await wait_physics_frames(1)
	return {"vehicle": vehicle, "parts": parts, "mirrors": mirrors}
