extends TestCase
## Tyres grip only so much: the vehicle never corners harder than its pack's lateral grip, and
## below walking pace, where the motion is kinematic, steering beyond it makes it run wide.

const WHEELBASE_M := 2.5
const GRIP_M_S2 := 8.0


func test_grip_does_not_limit_slow_turns() -> void:
	var steering_rad := BicycleModel.grip_limited_steering(0.4, 3.0, WHEELBASE_M, GRIP_M_S2)

	assert_almost_eq(steering_rad, 0.4, 1e-9)


func test_grip_caps_the_turn_at_speed() -> void:
	var speed_m_s := 50.0

	var steering_rad := BicycleModel.grip_limited_steering(0.5, speed_m_s, WHEELBASE_M, GRIP_M_S2)

	var lateral_m_s2 := speed_m_s * speed_m_s * tan(steering_rad) / WHEELBASE_M
	assert_almost_eq(lateral_m_s2, GRIP_M_S2, 1e-6)


func test_grip_keeps_the_turns_direction() -> void:
	var steering_rad := BicycleModel.grip_limited_steering(-0.5, 50.0, WHEELBASE_M, GRIP_M_S2)

	assert_true(steering_rad < 0.0, str(steering_rad))


func test_standing_still_turns_the_wheels_freely() -> void:
	assert_almost_eq(
		BicycleModel.grip_limited_steering(0.5, 0.0, WHEELBASE_M, GRIP_M_S2), 0.5, 1e-9
	)


func test_full_lock_at_180_km_h_never_corners_harder_than_the_grip() -> void:
	var vehicle := await _vehicle_on_flat_ground()
	var hardest_m_s2 := 0.0

	vehicle.command(50.0, 0.5)
	for step in Engine.physics_ticks_per_second * 3:
		await wait_physics_frames(1)
		var lateral_m_s2: float = vehicle.motion_state()["linear_acceleration_m_s2"].x
		hardest_m_s2 = maxf(hardest_m_s2, absf(lateral_m_s2))

	# The IMU sits at the origin, ahead of the centre of gravity: it also feels the yaw
	# accelerating.
	assert_true(hardest_m_s2 <= GRIP_M_S2 + 1.5, "IMU lateral %.2f m/s2" % hardest_m_s2)
	assert_almost_eq(vehicle.steering_rad, 0.5, 1e-9, "the wheels stay turned")


func test_refuses_a_pack_without_a_positive_grip() -> void:
	var directory := PackFixtures.fresh_directory("grip_missing")
	var manifest := PackFixtures.vehicle_manifest("small_car")
	manifest["vehicle"]["dynamics"]["friction"] = 0.0
	PackFixtures.write_pack(directory, manifest)

	var found := PackLibrary.scan([directory]).load_vehicle("small_car")

	assert_true(
		found.get("error", "").begins_with("small_car: vehicle.dynamics.friction"), str(found)
	)


func _vehicle_on_flat_ground() -> Vehicle:
	var directory := PackFixtures.fresh_directory("grip_flat")
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
