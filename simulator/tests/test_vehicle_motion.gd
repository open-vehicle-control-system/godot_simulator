extends TestCase
## The vehicle follows the speed and steering OVCS commands: a bicycle model about the rear
## axle, kept on the ground.


func test_bicycle_model_traces_its_turning_circle() -> void:
	var wheelbase_m := 2.5
	var radius_m := 10.0
	var steering_rad := atan(wheelbase_m / radius_m)
	var motion := {"rear_axle": Vector3.ZERO, "yaw_rad": 0.0}

	for step in 1000:
		motion = BicycleModel.advance(motion, 2.0, steering_rad, wheelbase_m, 0.01)

	# Heading +Z and turning left (+X): the centre is radius_m to the left.
	var centre := Vector3(radius_m, 0.0, 0.0)
	assert_almost_eq(motion["rear_axle"].distance_to(centre), radius_m, 0.05)
	assert_almost_eq(motion["yaw_rad"], 20.0 / radius_m, 1e-6)
	assert_almost_eq(motion["yaw_rate_rad_s"], 2.0 / radius_m, 1e-6)


func test_stands_on_the_ground_at_the_spawn_pose() -> void:
	var vehicle := await _vehicle_on_flat_track("on_ground", Vector3(1.0, 3.0, 2.0))

	await wait_physics_frames(2)

	assert_almost_eq(vehicle.global_position, Vector3(1.0, 0.0, 2.0), 1e-3)
	assert_almost_eq(vehicle.global_basis.y, Vector3.UP, 1e-4)


func test_drives_forward_at_the_commanded_speed() -> void:
	var vehicle := await _vehicle_on_flat_track("forward", Vector3.ZERO)

	vehicle.command(2.0, 0.0)
	await wait_physics_frames(60)

	var travelled := 2.0 * 60.0 / Engine.physics_ticks_per_second
	assert_almost_eq(vehicle.global_position, Vector3(0.0, 0.0, travelled), 1e-3)
	assert_almost_eq(vehicle.odometer_m, travelled, 1e-3)
	assert_almost_eq(vehicle.speed_m_s, 2.0, 1e-6)


func test_odometer_counts_reversing_as_negative() -> void:
	var vehicle := await _vehicle_on_flat_track("reverse", Vector3.ZERO)

	vehicle.command(-1.0, 0.0)
	await wait_physics_frames(30)

	assert_almost_eq(vehicle.odometer_m, -30.0 / Engine.physics_ticks_per_second, 1e-3)
	assert_true(vehicle.global_position.z < 0.0)


func test_reports_an_imu_reading_gravity_at_rest() -> void:
	var vehicle := await _vehicle_on_flat_track("imu", Vector3.ZERO)
	await wait_physics_frames(2)

	var state := vehicle.motion_state()

	assert_almost_eq(
		state["linear_acceleration_m_s2"], Vector3(0.0, Vehicle.GRAVITY_M_S2, 0.0), 1e-4
	)
	assert_almost_eq(state["linear_velocity_m_s"], Vector3.ZERO, 1e-6)


func _vehicle_on_flat_track(test_name: String, spawn: Vector3) -> Vehicle:
	var directory := PackFixtures.fresh_directory("motion_" + test_name)
	var track_pack := PackFixtures.write_pack(directory, PackFixtures.track_manifest("flat"))
	PackFixtures.write_flat_world(track_pack, 100.0)
	PackFixtures.write_pack(directory, PackFixtures.vehicle_manifest("small_car"))
	var library := PackLibrary.scan([directory])
	var track: TrackSpec = library.load_track("flat")["track"]
	var spec: VehicleSpec = library.load_vehicle("small_car")["vehicle"]
	var world: Node3D = TrackWorld.load_world(track)["world"]
	add_child(world)
	var vehicle := Vehicle.new()
	world.add_child(vehicle)
	vehicle.setup(spec, VehicleModel.build(spec)["model"])
	vehicle.global_transform = Transform3D(Basis.IDENTITY, spawn)
	await wait_physics_frames(1)
	return vehicle


func test_reports_the_motion_of_its_origin_ahead_of_the_rear_axle() -> void:
	var vehicle := await _vehicle_on_flat_track("turning_state", Vector3.ZERO)
	var steering_rad := 0.3

	vehicle.command(5.0, steering_rad)
	await wait_physics_frames(10)
	var state := vehicle.motion_state()

	# The fixture's origin is 1.3 m ahead of the rear axle.
	var yaw_rate := 5.0 * tan(steering_rad) / 2.5
	assert_almost_eq(vehicle.yaw_rate_rad_s, yaw_rate, 1e-5)
	assert_almost_eq(state["linear_velocity_m_s"], Vector3(1.3 * yaw_rate, 0.0, 5.0), 1e-4)
	var expected_acceleration := Vector3(
		5.0 * yaw_rate, Vehicle.GRAVITY_M_S2, -1.3 * yaw_rate * yaw_rate
	)
	assert_almost_eq(state["linear_acceleration_m_s2"], expected_acceleration, 1e-3)


func test_turns_left_under_positive_steering() -> void:
	var vehicle := await _vehicle_on_flat_track("turning", Vector3.ZERO)

	vehicle.command(5.0, 0.2)
	await wait_physics_frames(30)

	assert_true(vehicle.global_position.x > 0.1, "left of the start: %s" % vehicle.global_position)
	assert_true(vehicle.global_basis.z.x > 0.1, "heading left")
