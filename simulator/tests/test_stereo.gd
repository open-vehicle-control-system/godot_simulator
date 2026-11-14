extends TestCase
## The stereo camera's geometry and the pairs sent over the link.


func test_intrinsics_follow_from_resolution_and_horizontal_field_of_view() -> void:
	var optics := _optics(320, 180, 90.0, 0.12)

	var intrinsics := StereoCamera.intrinsics(optics)

	assert_almost_eq(intrinsics["fx"], 160.0, 1e-4)
	assert_almost_eq(intrinsics["fy"], 160.0, 1e-4)
	# OpenCV puts pixel centres on integers
	assert_eq(intrinsics["cx"], 159.5)
	assert_eq(intrinsics["cy"], 89.5)
	assert_almost_eq(intrinsics["vfov_deg"], rad_to_deg(2.0 * atan(90.0 / 160.0)), 1e-4)
	assert_eq(intrinsics["baseline_m"], 0.12)


func test_disparity_follows_from_depth_focal_length_and_baseline() -> void:
	var optics := _optics(320, 180, 90.0, 0.12)
	var cases := {1.0: 19.2, 9.6: 2.0, 192.0: 0.1}

	for depth_m in cases:
		assert_almost_eq(StereoCamera.disparity_px(optics, depth_m), cases[depth_m], 1e-5)


func test_calibration_gives_the_intrinsics_and_where_the_pair_sits() -> void:
	var optics := _optics(320, 180, 90.0, 0.12)
	optics.mount = Vector3(0.0, 1.16, 0.6)
	optics.pitch_deg = 2.0

	var calibration := StereoCamera.calibration(optics)

	assert_almost_eq(calibration["fx"], 160.0, 1e-4)
	assert_eq(calibration["baseline_m"], 0.12)
	assert_eq(calibration["mount_m"], [0.6, 0.0, 1.16])
	assert_eq(calibration["pitch_down_deg"], 2.0)
	assert_true(not calibration.has("ground_truth"))


func test_calibration_with_ground_truth_describes_its_maps_and_classes() -> void:
	var calibration := StereoCamera.calibration_with_ground_truth(_optics(320, 180, 90.0, 0.12))

	var ground_truth: Dictionary = calibration["ground_truth"]
	assert_eq(
		ground_truth["segmentation_classes"][2], {"id": 2, "name": "road", "colour": [128, 64, 128]}
	)
	assert_true(ground_truth.has("depth"))
	assert_true(ground_truth.has("disparity"))


func test_cameras_are_parallel_a_baseline_apart_looking_forward() -> void:
	var optics := _optics(320, 180, 90.0, 0.2)
	optics.mount = Vector3(0.0, 1.2, 0.6)
	var vehicle := Node3D.new()
	add_child(vehicle)
	vehicle.global_transform = Transform3D(Basis(Vector3.UP, PI / 2.0), Vector3(10.0, 0.0, 0.0))
	var stereo := StereoCamera.new()
	add_child(stereo)
	stereo.setup(vehicle, optics)

	await wait_physics_frames(2)

	var left := stereo.cameras[0].global_transform
	var right := stereo.cameras[1].global_transform
	# The vehicle faces world +X, so its left is world -Z.
	assert_almost_eq(left.origin, Vector3(10.6, 1.2, -0.1), 1e-4)
	assert_almost_eq(right.origin, Vector3(10.6, 1.2, 0.1), 1e-4)
	assert_almost_eq(-left.basis.z, Vector3(1.0, 0.0, 0.0), 1e-4, "looks forward")
	assert_true(left.basis.is_equal_approx(right.basis), "parallel")


func test_pitch_tilts_both_cameras_down() -> void:
	var optics := _optics(320, 180, 90.0, 0.2)
	optics.pitch_deg = 10.0
	var vehicle := Node3D.new()
	add_child(vehicle)
	var stereo := StereoCamera.new()
	add_child(stereo)
	stereo.setup(vehicle, optics)

	await wait_physics_frames(2)

	var looking := -stereo.cameras[0].global_basis.z
	assert_almost_eq(looking, Vector3(0.0, -sin(deg_to_rad(10.0)), cos(deg_to_rad(10.0))), 1e-4)


func test_sends_jpeg_pairs_at_the_camera_rate_with_one_time_per_pair() -> void:
	var server := LinkTestServer.new()
	var vehicle := await _vehicle()
	var link := SimulatorLink.new()
	add_child(link)
	link.setup(vehicle, "127.0.0.1", server.port)
	await _poll_until(server, func(): return link.connected and link.time_s > 0.5)
	var sender := StereoSender.new()
	add_child(sender)

	sender.setup(link, _hand_over_solid_pair, 10.0)
	await _poll_until(server, func(): return not server.of_type("image").is_empty())
	var started_s: float = server.of_type("image")[0]["time_s"]
	await _poll_until(server, func(): return link.time_s - started_s >= 1.1)

	var images := server.of_type("image")
	var in_one_second := images.filter(func(image): return image["time_s"] < started_s + 0.95)
	assert_eq(in_one_second.size(), 20, "10 pairs in 1 s at 10 Hz")
	for index in range(0, images.size() - 1, 2):
		assert_eq(images[index]["camera"], "left")
		assert_eq(images[index + 1]["camera"], "right")
		assert_eq(images[index]["time_s"], images[index + 1]["time_s"])
		assert_eq(images[index]["format"], "jpeg")
	var first_body: PackedByteArray = server.bodies[server.headers.find(images[0])]
	assert_eq(first_body.slice(0, 2), PackedByteArray([0xFF, 0xD8]), "a JPEG")
	server.stop()


func test_a_pair_handed_over_later_carries_the_time_it_was_asked_for() -> void:
	var server := LinkTestServer.new()
	var vehicle := await _vehicle()
	var link := SimulatorLink.new()
	add_child(link)
	link.setup(vehicle, "127.0.0.1", server.port)
	await _poll_until(server, func(): return link.connected and link.time_s > 0.5)
	var sender := StereoSender.new()
	add_child(sender)
	var asked := []  # [time asked at, the function to hand the pair to]

	sender.setup(link, func(deliver): asked.append([link.time_s, deliver]), 10.0)
	await _poll_until(server, func(): return not asked.is_empty())
	await _poll_frames(server, 30)
	assert_eq(asked.size(), 1, "asked again before the pair was handed over")
	asked[0][1].call(_solid_pair())
	await _poll_until(server, func(): return server.of_type("image").size() >= 2)

	# The pair shows the frame drawn one step before it was asked for.
	var step_s := 1.0 / Engine.physics_ticks_per_second
	assert_almost_eq(server.of_type("image")[0]["time_s"], asked[0][0] - step_s, step_s + 1e-3)
	server.stop()


func _hand_over_solid_pair(deliver: Callable) -> void:
	deliver.call(_solid_pair())


func _solid_pair() -> Array[Image]:
	var left := Image.create(16, 8, false, Image.FORMAT_RGB8)
	left.fill(Color.RED)
	var right := Image.create(16, 8, false, Image.FORMAT_RGB8)
	right.fill(Color.BLUE)
	return [left, right]


func _optics(
	width_px: int, height_px: int, hfov_deg: float, baseline_m: float
) -> VehicleSpec.StereoOptics:
	var optics := VehicleSpec.StereoOptics.new()
	optics.width_px = width_px
	optics.height_px = height_px
	optics.hfov_deg = hfov_deg
	optics.baseline_m = baseline_m
	optics.rate_hz = 10.0
	return optics


func _vehicle() -> Vehicle:
	var directory := PackFixtures.fresh_directory("stereo_vehicle")
	PackFixtures.write_pack(directory, PackFixtures.vehicle_manifest("small_car"))
	var spec: VehicleSpec = PackLibrary.scan([directory]).load_vehicle("small_car")["vehicle"]
	var vehicle := Vehicle.new()
	add_child(vehicle)
	vehicle.setup(spec, VehicleModel.build(spec)["model"])
	await wait_physics_frames(1)
	return vehicle


func _poll_until(server: LinkTestServer, condition: Callable) -> void:
	for frame in 5 * Engine.physics_ticks_per_second:
		await get_tree().physics_frame
		server.poll()
		if condition.call():
			return
	fail("timed out")


func _poll_frames(server: LinkTestServer, frames: int) -> void:
	for frame in frames:
		await get_tree().physics_frame
		server.poll()
