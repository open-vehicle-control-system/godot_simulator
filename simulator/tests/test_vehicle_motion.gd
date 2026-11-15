extends TestCase
## The vehicle follows the speed and steering OVCS commands, by the dynamic bicycle model, kept on
## the ground.


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


func test_reports_the_motion_of_its_origin_in_a_steady_slow_turn() -> void:
	var vehicle := await _vehicle_on_flat_track("turning_state", Vector3.ZERO)
	var steering_rad := 0.3

	vehicle.command(5.0, steering_rad)
	await wait_physics_frames(Engine.physics_ticks_per_second * 2)
	var state := vehicle.motion_state()

	# Slow, the tyres barely slip: the turn is the kinematic one about the rear axle, which the
	# fixture's origin is 1.3 m ahead of.
	var yaw_rate := 5.0 * tan(steering_rad) / 2.5
	assert_almost_eq(vehicle.yaw_rate_rad_s, yaw_rate, yaw_rate * 0.05)
	assert_almost_eq(state["linear_velocity_m_s"], Vector3(1.3 * yaw_rate, 0.0, 5.0), 0.15)
	var expected_acceleration := Vector3(
		5.0 * vehicle.yaw_rate_rad_s, Vehicle.GRAVITY_M_S2, -1.3 * yaw_rate * yaw_rate
	)
	assert_almost_eq(state["linear_acceleration_m_s2"], expected_acceleration, 0.1)


func test_braking_hard_in_a_fast_corner_slides_it_sideways() -> void:
	var vehicle := await _vehicle_on_wide_ground()
	vehicle.command(22.0, 0.04)
	await wait_physics_frames(Engine.physics_ticks_per_second * 4)
	var speed_m_s := 22.0

	for step in Engine.physics_ticks_per_second:
		speed_m_s -= 6.0 / Engine.physics_ticks_per_second
		vehicle.command(speed_m_s, 0.04)
		await wait_physics_frames(1)
	var before := vehicle.global_position
	await wait_physics_frames(1)

	var state := vehicle.motion_state()
	var velocity: Vector3 = state["linear_velocity_m_s"]
	assert_true(velocity.x < -2.0, "sliding out of the turn: %s" % velocity)
	var travel := vehicle.global_position - before
	var heading := vehicle.global_basis.z
	var angle_deg := rad_to_deg(Vector2(heading.x, heading.z).angle_to(Vector2(travel.x, travel.z)))
	assert_true(absf(angle_deg) > 10.0, "heading %.1f deg off its path" % angle_deg)
	assert_almost_eq(float(state["angular_velocity_rad_s"].y), vehicle.yaw_rate_rad_s, 1e-6)


func _vehicle_on_wide_ground() -> Vehicle:
	var directory := PackFixtures.fresh_directory("motion_wide")
	PackFixtures.write_pack(directory, PackFixtures.vehicle_manifest("small_car"))
	var spec: VehicleSpec = PackLibrary.scan([directory]).load_vehicle("small_car")["vehicle"]
	var ground := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4000.0, 1.0, 4000.0)
	shape.shape = box
	ground.add_child(shape)
	ground.position = Vector3(0.0, -0.5, 0.0)
	add_child(ground)
	var vehicle := Vehicle.new()
	add_child(vehicle)
	vehicle.setup(spec, VehicleModel.build(spec)["model"])
	await wait_physics_frames(2)
	return vehicle


func test_turns_left_under_positive_steering() -> void:
	var vehicle := await _vehicle_on_flat_track("turning", Vector3.ZERO)

	vehicle.command(5.0, 0.2)
	await wait_physics_frames(30)

	assert_true(vehicle.global_position.x > 0.1, "left of the start: %s" % vehicle.global_position)
	assert_true(vehicle.global_basis.z.x > 0.1, "heading left")
