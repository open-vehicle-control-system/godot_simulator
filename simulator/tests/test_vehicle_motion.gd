extends TestCase
## The vehicle moves by its actuation through its tyres, on its springs.


func test_settles_level_on_its_springs_at_its_ride_height() -> void:
	var vehicle := await _small_car(Transform3D(Basis.IDENTITY, Vector3(1.0, 0.3, 2.0)))

	await wait_physics_frames(Engine.physics_ticks_per_second * 2)

	assert_almost_eq(vehicle.global_position, Vector3(1.0, 0.0, 2.0), 0.01)
	assert_almost_eq(vehicle.global_basis.y, Vector3.UP, 1e-3)
	assert_eq(vehicle.wheel_in_contact, [true, true, true, true] as Array[bool])


func test_reports_an_imu_reading_gravity_at_rest() -> void:
	var vehicle := await _small_car()

	var state := vehicle.motion_state()

	assert_almost_eq(
		state["linear_acceleration_m_s2"], Vector3(0.0, Vehicle.GRAVITY_M_S2, 0.0), 0.01
	)
	assert_almost_eq(state["linear_velocity_m_s"], Vector3.ZERO, 0.01)


func test_drive_torque_moves_it_and_its_wheels_roll_with_it() -> void:
	var vehicle := await _small_car()

	vehicle.actuate(Actuation.of(600.0, 0.0, 0.0, 1.0))
	await wait_physics_frames(Engine.physics_ticks_per_second * 2)

	assert_true(vehicle.speed_m_s > 1.5, "speed %.2f" % vehicle.speed_m_s)
	assert_almost_eq(vehicle.odometer_m, vehicle.global_position.z, 0.05)
	var rolling_rad_s := vehicle.speed_m_s / vehicle.spec.wheel_radius_m
	for index in 4:
		assert_almost_eq(vehicle.wheels.omega_rad_s[index], rolling_rad_s, rolling_rad_s * 0.05)
	var wheels := vehicle.wheel_states()
	assert_almost_eq(
		wheels["rear_left"]["angle_rad"],
		vehicle.odometer_m / vehicle.spec.wheel_radius_m,
		0.5,
		"the rear wheels turned as far as it went"
	)


func test_reversing_counts_the_odometer_down() -> void:
	var vehicle := await _small_car()

	vehicle.actuate(Actuation.of(-400.0, 0.0, 0.0, 1.0))
	await wait_physics_frames(Engine.physics_ticks_per_second)

	assert_true(vehicle.odometer_m < -0.1, "odometer %.3f" % vehicle.odometer_m)
	assert_true(vehicle.global_position.z < -0.1)


func test_turns_left_under_positive_steering() -> void:
	var vehicle := await _small_car()

	VehicleFixtures.hold(self, vehicle, 5.0, 0.2)
	await wait_physics_frames(Engine.physics_ticks_per_second * 2)

	assert_true(vehicle.global_position.x > 0.1, "left of the start: %s" % vehicle.global_position)
	assert_true(vehicle.global_basis.z.x > 0.1, "heading left")


func test_a_slow_steady_turn_is_the_kinematic_one() -> void:
	var vehicle := await _small_car()
	var steering_rad := 0.3

	VehicleFixtures.hold(self, vehicle, 3.0, steering_rad)
	await wait_physics_frames(Engine.physics_ticks_per_second * 4)
	var state := vehicle.motion_state()

	# Slow, the tyres barely slip: the turn is about the rear axle, which the fixture's origin
	# is 1.3 m ahead of.
	var speed_m_s := vehicle.speed_m_s
	var yaw_rate := speed_m_s * tan(steering_rad) / vehicle.spec.wheelbase_m()
	assert_almost_eq(vehicle.yaw_rate_rad_s, yaw_rate, yaw_rate * 0.05)
	assert_almost_eq(state["linear_velocity_m_s"], Vector3(1.3 * yaw_rate, 0.0, speed_m_s), 0.15)
	assert_almost_eq(
		float(state["linear_acceleration_m_s2"].x), speed_m_s * yaw_rate, 0.15, "centripetal"
	)


func test_leans_out_of_a_turn_and_dives_under_braking() -> void:
	var vehicle := await _small_car()
	VehicleFixtures.hold(self, vehicle, 15.0, 0.08)
	await wait_physics_frames(Engine.physics_ticks_per_second * 10)
	var lateral_g := absf(vehicle.speed_m_s * vehicle.yaw_rate_rad_s) / Vehicle.GRAVITY_M_S2

	# Turning left, the body leans to the right: its left side, +X, rises.
	var roll_deg := rad_to_deg(asin(vehicle.global_basis.x.y))
	assert_true(lateral_g > 0.3, "corners at %.2f g" % lateral_g)
	assert_almost_eq(
		roll_deg / lateral_g,
		rad_to_deg(Vehicle.ROLL_GRADIENT_RAD_PER_G),
		1.5,
		"leans %.2f deg at %.2f g" % [roll_deg, lateral_g]
	)

	VehicleFixtures.hold(self, vehicle, 0.0, 0.0)
	await wait_physics_frames(Engine.physics_ticks_per_second / 2)
	var pitch_deg := rad_to_deg(asin(-vehicle.global_basis.z.y))
	assert_true(pitch_deg > 0.5, "the nose dips %.2f deg" % pitch_deg)


func test_braking_the_rear_hard_in_a_fast_corner_slides_it_sideways() -> void:
	# Brakes biased to the rear, without a proportioning valve to hold them back.
	var spec := VehicleFixtures.small_car()
	spec.brake_bias_front = 0.2
	spec.rear_brake_margin = -1.0
	var vehicle := await VehicleFixtures.on_flat_ground(self, spec)
	VehicleFixtures.hold(self, vehicle, 22.0, 0.04)
	await wait_physics_frames(Engine.physics_ticks_per_second * 8)
	VehicleFixtures.release(vehicle)

	var braking_n_m := spec.mass_kg * 7.0 * spec.wheel_radius_m
	vehicle.actuate(Actuation.of(0.0, braking_n_m, 0.04, 0.0))
	await wait_physics_frames(Engine.physics_ticks_per_second)
	var before := vehicle.global_position
	await wait_physics_frames(1)

	var travel := vehicle.global_position - before
	var heading := vehicle.global_basis.z
	var angle_deg := rad_to_deg(Vector2(heading.x, heading.z).angle_to(Vector2(travel.x, travel.z)))
	assert_true(absf(angle_deg) > 10.0, "heading %.1f deg off its path" % angle_deg)


func test_its_brakes_hold_it_on_a_slope_and_it_rolls_down_without_them() -> void:
	var held := await _small_car_on_a_slope(10.0)
	held.park()
	var start := held.global_position
	await wait_physics_frames(Engine.physics_ticks_per_second * 3)
	assert_true(
		(held.global_position - start).length() < 0.01,
		"held: moved %s" % (held.global_position - start)
	)

	held.actuate(Actuation.of(0.0, 0.0, 0.0, 0.0))
	await wait_physics_frames(Engine.physics_ticks_per_second * 2)
	assert_true(held.global_position.z < start.z - 1.0, "rolled down to %s" % held.global_position)


func _small_car(where := Transform3D.IDENTITY) -> Vehicle:
	return await VehicleFixtures.on_flat_ground(self, VehicleFixtures.small_car(), where)


func _small_car_on_a_slope(slope_deg: float) -> Vehicle:
	## A small car facing up a slope rising towards +Z.
	var tilt := Basis(Vector3.RIGHT, -deg_to_rad(slope_deg))
	var slope := StaticBody3D.new()
	slope.collision_layer = CollisionLayers.GROUND
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(40.0, 1.0, 80.0)
	shape.shape = box
	slope.add_child(shape)
	slope.transform = Transform3D(tilt, tilt * Vector3(0.0, -0.5, 0.0))
	add_child(slope)
	var vehicle := Vehicle.new()
	add_child(vehicle)
	var spec := VehicleFixtures.small_car()
	vehicle.setup(spec, VehicleModel.build(spec)["model"])
	vehicle.place(Transform3D(tilt, Vector3.ZERO))
	await wait_physics_frames(Engine.physics_ticks_per_second)
	return vehicle
