extends TestCase
## A vehicle's powertrain: as its pack describes it, the torque its motor gives through the
## selected gear and what the road and the air take back.

const GRAVITY_M_S2 := 9.81


func test_the_overall_ratio_is_the_selected_gear_times_the_final_drive() -> void:
	var powertrain := _spec().powertrain

	assert_almost_eq(Powertrain.overall_ratio(powertrain, 1), 8.0)
	assert_almost_eq(Powertrain.overall_ratio(powertrain, 2), 4.0)


func test_the_motor_gives_its_torque_then_its_power_and_nothing_past_its_rpm_limit() -> void:
	# The fixture: 250 Nm, 80 kW and 10,000 rpm through 8 at 90 % on wheels of 0.3 m; its
	# power takes over at 12 m/s and its rpm limit comes at 39.3 m/s.
	var cases := [
		[0.0, 250.0 * 8.0 * 0.9 / 0.3],
		[5.0, 250.0 * 8.0 * 0.9 / 0.3],
		[20.0, 80000.0 * 0.9 / 20.0],
		[38.0, 80000.0 * 0.9 / 38.0],
		[40.0, 0.0],
	]
	for case in cases:
		assert_almost_eq(Powertrain.motor_force_n(_spec(), 1, case[0]), case[1], 0.01, str(case))


func test_an_automatic_gearbox_picks_the_gear_that_pushes_hardest_the_highest_on_a_tie() -> void:
	var spec := _spec()
	spec.powertrain.gear = PowertrainSpec.AUTOMATIC
	# At 30 m/s both gears are held to the motor's power; at 45 m/s first is past its limit.
	var cases := {0.0: 1, 5.0: 1, 30.0: 2, 45.0: 2, -5.0: 1}
	for speed_m_s in cases:
		assert_eq(Powertrain.gear_at(spec, speed_m_s), cases[speed_m_s], str(speed_m_s))


func test_a_selected_gear_stays_whatever_the_speed() -> void:
	var spec := _spec()
	spec.powertrain.gear = 2

	assert_eq(Powertrain.gear_at(spec, 0.0), 2)
	assert_eq(Powertrain.gear_at(spec, 60.0), 2)


func test_drag_and_rolling_resistance_hold_the_vehicle_back() -> void:
	var rolling_n := 0.011 * 1200.0 * GRAVITY_M_S2
	var cases := [[0.0, rolling_n], [20.0, 0.5 * 1.2 * 0.65 * 400.0 + rolling_n]]
	for case in cases:
		assert_almost_eq(Powertrain.resistance_n(_spec(), case[0]), case[1], 0.01, str(case))


func test_an_automatic_gearbox_shifts_up_short_of_the_rpm_limit() -> void:
	var spec := _spec()
	spec.powertrain.gear = PowertrainSpec.AUTOMATIC
	# Held to its torque alone, first pushes twice as hard as second up to where it shifts.
	spec.powertrain.max_power_w = 1.0e6
	var shift_m_s := Powertrain.SHIFT_RPM_SHARE * 10000.0 / 60.0 / 8.0 * TAU * 0.3

	assert_eq(Powertrain.gear_at(spec, shift_m_s - 0.1), 1)
	assert_eq(Powertrain.gear_at(spec, shift_m_s + 0.1), 2)


func test_the_wheels_get_the_motors_torque_through_the_gear() -> void:
	var spec := _spec()
	# 250 Nm through 8 at 90 %; past 10,000 rpm in first (wheels at 130.9 rad/s), nothing.
	var cases := [[0.0, 1800.0], [-20.0, 1800.0], [131.0, 0.0]]
	for case in cases:
		assert_almost_eq(Powertrain.wheel_torque_n_m(spec, 1, case[0]), case[1], 0.01, str(case))


func test_the_driveline_turns_with_the_wheels_heavier_in_a_lower_gear() -> void:
	var spec := _spec()

	var first := Powertrain.driveline_inertia_kg_m2(spec, 1)
	var second := Powertrain.driveline_inertia_kg_m2(spec, 2)

	assert_almost_eq(first, 0.0025 * 64.0 * 1200.0 * 0.09, 1e-9)
	assert_almost_eq(first / second, 4.0, 1e-9)


func test_reads_the_powertrain() -> void:
	var directory := PackFixtures.fresh_directory("powertrain")
	PackFixtures.write_pack(directory, PackFixtures.vehicle_manifest("small_car"))

	var spec: VehicleSpec = PackLibrary.scan([directory]).load_vehicle("small_car")["vehicle"]

	var powertrain := spec.powertrain
	assert_almost_eq(powertrain.max_power_w, 80000.0)
	assert_almost_eq(powertrain.max_torque_n_m, 250.0)
	assert_almost_eq(powertrain.max_rpm, 10000.0)
	assert_eq(powertrain.gear_ratios, [2.0, 1.0] as Array[float])
	assert_almost_eq(powertrain.final_drive_ratio, 4.0)
	assert_eq(powertrain.gear, 1)
	assert_almost_eq(powertrain.driveline_efficiency, 0.9)
	assert_almost_eq(powertrain.rolling_resistance_coefficient, 0.011)
	assert_almost_eq(powertrain.drag_area_m2, 0.65)


func test_refuses_a_powertrain_out_of_range() -> void:
	var cases := {
		"motor.max_power_w": 0.0,
		"motor.max_torque_n_m": -1.0,
		"motor.max_rpm": 0.0,
		"gear_ratios": [],
		"gear_ratios.1": [2.0, 0.0],
		"final_drive_ratio": 0.0,
		"gear": 0,
		"driveline_efficiency": 1.1,
		"rolling_resistance_coefficient": 0.0,
		"drag_area_m2": 0.0,
	}
	for field in cases:
		var found := _vehicle_with_powertrain(field, cases[field])

		assert_eq(
			found, {"error": "small_car: vehicle.powertrain.%s is out of range" % field}, field
		)


func test_the_gear_is_one_the_gearbox_has_or_automatic() -> void:
	var cases := {
		3: "small_car: vehicle.powertrain.gear is out of range",
		1.5: "small_car: vehicle.powertrain.gear is out of range",
		"manual": "small_car: vehicle.powertrain.gear is not one of automatic",
	}
	for gear in cases:
		assert_eq(_vehicle_with_powertrain("gear", gear), {"error": cases[gear]}, str(gear))
	var automatic: VehicleSpec = _vehicle_with_powertrain("gear", "automatic")["vehicle"]
	assert_eq(automatic.powertrain.gear, PowertrainSpec.AUTOMATIC)


func _vehicle_with_powertrain(field: String, value: Variant) -> Dictionary:
	var directory := PackFixtures.fresh_directory("powertrain_" + field.replace(".", "_"))
	var manifest := PackFixtures.vehicle_manifest("small_car")
	var powertrain: Dictionary = manifest["vehicle"]["powertrain"]
	if field.begins_with("motor"):
		powertrain["motor"][field.get_slice(".", 1)] = value
	else:
		powertrain[field.get_slice(".", 0)] = value
	PackFixtures.write_pack(directory, manifest)
	return PackLibrary.scan([directory]).load_vehicle("small_car")


func test_a_setting_selects_another_gear_for_the_run() -> void:
	var directory := PackFixtures.fresh_directory("gear_setting")
	PackFixtures.write_pack(directory, PackFixtures.vehicle_manifest("small_car"))
	var library := PackLibrary.scan([directory])

	var found := library.load_vehicle("small_car", [["vehicle.powertrain.gear", 2]])

	var spec: VehicleSpec = found["vehicle"]
	assert_eq(spec.powertrain.gear, 2)


func _spec() -> VehicleSpec:
	## The fixture: 1200 kg on wheels of 0.3 m, two gears of 2 and 1 and a final drive of 4.
	var found := VehicleSpec.parse(PackFixtures.vehicle_manifest("small_car"), "")
	return found["vehicle"]
