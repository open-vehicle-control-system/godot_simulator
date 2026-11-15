extends TestCase
## The wheels' spin under drive, brakes and their tyres, through an open differential.

const STEP_S := 1.0 / 60.0
const DRIVELINE_KG_M2 := 4.0


func test_driven_wheels_in_the_air_spin_up_with_the_driveline() -> void:
	var wheels := Wheels.of(VehicleFixtures.small_car())

	for step in 60:
		wheels.advance(_contacts(0.0, 0.0), 100.0, _brakes(0.0), DRIVELINE_KG_M2, STEP_S)

	var expected := 100.0 * 1.0 / (2.0 * wheels.wheel_inertia_kg_m2 + DRIVELINE_KG_M2)
	assert_almost_eq(wheels.omega_rad_s[0], expected, expected * 1e-6)
	assert_almost_eq(wheels.omega_rad_s[1], expected, expected * 1e-6)
	assert_eq(wheels.omega_rad_s[2], 0.0, "the rear is not driven")
	assert_almost_eq(wheels.angle_rad[0], expected * 0.5, expected * 0.01, "turned")


func test_a_lifted_driven_wheel_spins_while_the_one_on_the_ground_holds() -> void:
	var wheels := Wheels.of(VehicleFixtures.small_car())
	var load_n := wheels.tyres[0].static_load_n
	var contacts := _contacts(load_n, 0.0)
	contacts[0]["load_n"] = 0.0

	for step in 60:
		wheels.advance(contacts, 200.0, _brakes(0.0), DRIVELINE_KG_M2, STEP_S)

	assert_true(wheels.omega_rad_s[0] > 10.0, "the lifted wheel spins: %s" % wheels.omega_rad_s)
	assert_true(absf(wheels.omega_rad_s[1]) < 0.1, "the other holds: %s" % wheels.omega_rad_s)


func test_wheels_spin_on_ice_under_more_torque_than_it_holds() -> void:
	var spec := VehicleFixtures.small_car()
	spec.friction = 0.1
	var wheels := Wheels.of(spec)
	var held_still := _contacts(wheels.tyres[0].static_load_n, 0.0)

	var forces: Array[Vector2] = []
	for step in 60:
		forces = wheels.advance(held_still, 1000.0, _brakes(0.0), 0.0, STEP_S)

	assert_true(wheels.omega_rad_s[0] > 20.0, "spins: %s" % wheels.omega_rad_s)
	var grip_n := 0.1 * wheels.tyres[0].static_load_n
	assert_true(forces[0].x <= grip_n * 1.001 and forces[0].x > 0.7 * grip_n, str(forces[0]))


func test_brakes_hold_the_wheels_against_less_torque_than_theirs() -> void:
	var wheels := Wheels.of(VehicleFixtures.small_car())

	for step in 60:
		wheels.advance(_contacts(0.0, 0.0), 300.0, _brakes(200.0), DRIVELINE_KG_M2, STEP_S)

	assert_almost_eq(wheels.omega_rad_s[0], 0.0, 1e-6)
	assert_almost_eq(wheels.omega_rad_s[1], 0.0, 1e-6)


func test_brakes_stop_a_spinning_wheel_and_never_turn_it_back() -> void:
	var wheels := Wheels.of(VehicleFixtures.small_car())
	wheels.roll_at(10.0)

	var lowest := INF
	# 100 N m on each wheel stops the driven pair and its driveline within about 2 s.
	for step in 180:
		wheels.advance(_contacts(0.0, 0.0), 0.0, _brakes(100.0), DRIVELINE_KG_M2, STEP_S)
		lowest = minf(lowest, wheels.omega_rad_s[0])

	assert_almost_eq(wheels.omega_rad_s[0], 0.0, 1e-9)
	assert_almost_eq(wheels.omega_rad_s[3], 0.0, 1e-9)
	assert_true(lowest >= 0.0, "never backwards: %f" % lowest)


func test_a_wheel_rolling_with_the_ground_passes_no_force() -> void:
	var wheels := Wheels.of(VehicleFixtures.small_car())
	wheels.roll_at(20.0)

	var forces := wheels.advance(
		_contacts(wheels.tyres[0].static_load_n, 20.0), 0.0, _brakes(0.0), 0.0, STEP_S
	)

	for index in 4:
		var rolling_n := wheels.rolling_resistance * wheels.tyres[index].static_load_n
		assert_true(forces[index].length() <= rolling_n, "only rolling: %s" % forces[index])
	assert_almost_eq(wheels.omega_rad_s[0], 20.0 / wheels.radius_m, 0.2)


func test_a_wheel_sliding_sideways_is_pushed_back() -> void:
	var wheels := Wheels.of(VehicleFixtures.small_car())
	var contacts := _contacts(wheels.tyres[0].static_load_n, 0.0)
	for contact in contacts:
		contact["across_m_s"] = 0.5

	var forces := wheels.advance(contacts, 0.0, _brakes(0.0), 0.0, STEP_S)

	for force in forces:
		assert_true(force.y < 0.0, "pushed back right: %s" % force)


static func _contacts(load_n: float, along_m_s: float) -> Array[Dictionary]:
	var contacts: Array[Dictionary] = []
	for index in 4:
		contacts.append({"along_m_s": along_m_s, "across_m_s": 0.0, "load_n": load_n})
	return contacts


static func _brakes(torque_n_m: float) -> PackedFloat64Array:
	return PackedFloat64Array([torque_n_m, torque_n_m, torque_n_m, torque_n_m])
