extends TestCase
## What the wheels measure is not always how the body moves: a lifted wheel or one on ice
## spins, a wall stops the body while the drive still pushes.


func test_wheels_in_the_air_spin_and_the_body_stays() -> void:
	var vehicle := await _small_car_on_a_stand()
	var start := vehicle.global_position

	vehicle.actuate(Actuation.of(150.0, 0.0, 0.0, 1.0))
	await wait_physics_frames(Engine.physics_ticks_per_second)

	assert_eq(vehicle.wheel_in_contact, [false, false, false, false] as Array[bool])
	var wheels := vehicle.wheel_states()
	assert_true(wheels["front_left"]["omega_rad_s"] > 10.0, str(wheels))
	assert_eq(wheels["rear_left"]["omega_rad_s"], 0.0, "the rear is not driven")
	assert_true((vehicle.global_position - start).length() < 0.02, "the body stays")


func test_on_ice_the_driven_wheels_spin_faster_than_it_goes() -> void:
	var spec := VehicleFixtures.small_car()
	spec.friction = 0.05
	var vehicle := await VehicleFixtures.on_flat_ground(self, spec)

	vehicle.actuate(Actuation.of(1500.0, 0.0, 0.0, 1.0))
	await wait_physics_frames(Engine.physics_ticks_per_second)

	var wheel_m_s := vehicle.driven_wheel_speed_rad_s() * spec.wheel_radius_m
	assert_true(
		wheel_m_s > 3.0 * vehicle.speed_m_s,
		"wheels %.2f m/s, body %.2f m/s" % [wheel_m_s, vehicle.speed_m_s]
	)
	assert_true(vehicle.speed_m_s > 0.0, "the little grip there is moves it")


func _small_car_on_a_stand() -> Vehicle:
	## A small car lifted on a stand under its body, its wheels hanging free.
	var stand := StaticBody3D.new()
	stand.collision_layer = CollisionLayers.OBSTACLES
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.6, 1.0, 1.5)
	shape.shape = box
	stand.add_child(shape)
	stand.position = Vector3(0.0, 0.0, 0.0)
	add_child(stand)
	var vehicle := Vehicle.new()
	add_child(vehicle)
	var spec := VehicleFixtures.small_car()
	vehicle.setup(spec, VehicleModel.build(spec)["model"])
	vehicle.place(Transform3D(Basis.IDENTITY, Vector3(0.0, 0.3, 0.0)))
	await wait_physics_frames(Engine.physics_ticks_per_second)
	return vehicle
