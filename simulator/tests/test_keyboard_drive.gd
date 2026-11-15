extends TestCase
## Driving with the arrow keys under --keyboard: speed and steering from the keys held, the
## speed from the vehicle's powertrain.

const STEP_S := 1.0 / 60.0
const STOPPED := {"speed_m_s": 0.0, "steering_rad": 0.0}


func test_up_accelerates_forward_at_full_throttle() -> void:
	var spec := _fixture()

	var drive := KeyboardDrive.next(STOPPED, {"up": true}, STEP_S, spec)

	var expected_m_s2 := Powertrain.full_throttle_acceleration_m_s2(spec, 0.0)
	assert_almost_eq(drive["speed_m_s"], expected_m_s2 * STEP_S, 1e-6)


func test_ovcs1_in_first_gear_tops_out_at_the_motors_rpm_limit() -> void:
	var drive := _hold(_ovcs1(1), {"up": true}, 60.0)

	# 10,500 rpm through 3.300 x 3.389 on wheels of 0.296 m: 104.8 km/h.
	var top_m_s := 10500.0 / 60.0 / (3.300 * 3.389) * TAU * 0.296
	assert_almost_eq(drive["speed_m_s"], top_m_s, 1e-3)


func test_ovcs1_in_third_gear_is_held_by_power_and_drag_below_its_rpm_limit() -> void:
	var spec := _ovcs1(3)

	var drive := _hold(spec, {"up": true}, 150.0)
	var later := _hold(spec, {"up": true}, 30.0, drive)

	var speed_m_s: float = later["speed_m_s"]
	assert_true(speed_m_s < 0.8 * Powertrain.rpm_limited_speed_m_s(spec), str(speed_m_s))
	assert_true(speed_m_s > 50.0 and speed_m_s < 58.0, str(speed_m_s))
	assert_almost_eq(speed_m_s, drive["speed_m_s"], 0.3, "steady")


func test_ovcs1_pulls_away_harder_in_first_than_in_third() -> void:
	var first := _hold(_ovcs1(1), {"up": true}, 5.0)
	var third := _hold(_ovcs1(3), {"up": true}, 5.0)

	assert_true(first["speed_m_s"] > third["speed_m_s"], "%s %s" % [first, third])


func test_down_brakes_then_reverses_once_stopped() -> void:
	var spec := _fixture()
	var moving := {"speed_m_s": 10.0, "steering_rad": 0.0}

	var braking := KeyboardDrive.next(moving, {"down": true}, STEP_S, spec)
	var reversing := _hold(spec, {"down": true}, 4.0)

	assert_almost_eq(braking["speed_m_s"], 10.0 - KeyboardDrive.BRAKING_M_S2 * STEP_S, 1e-5)
	assert_almost_eq(reversing["speed_m_s"], -KeyboardDrive.MAX_REVERSE_SPEED_M_S, 1e-6)


func test_up_brakes_a_reversing_vehicle() -> void:
	var reversing := {"speed_m_s": -3.0, "steering_rad": 0.0}

	var drive := KeyboardDrive.next(reversing, {"up": true}, STEP_S, _fixture())

	assert_almost_eq(drive["speed_m_s"], -3.0 + KeyboardDrive.BRAKING_M_S2 * STEP_S, 1e-5)


func test_coasts_by_drag_and_rolling_resistance_with_no_key() -> void:
	var spec := _fixture()
	var fast := {"speed_m_s": 20.0, "steering_rad": 0.0}

	var drive := KeyboardDrive.next(fast, {}, STEP_S, spec)

	var expected_m_s2 := Powertrain.coasting_deceleration_m_s2(spec, 20.0)
	assert_almost_eq(drive["speed_m_s"], 20.0 - expected_m_s2 * STEP_S, 1e-6)


func test_coasts_down_to_a_stop_with_no_key() -> void:
	var drive := _hold(_fixture(), {}, 60.0, {"speed_m_s": 5.0, "steering_rad": 0.0})

	assert_eq(drive["speed_m_s"], 0.0)


func test_left_steers_left_and_returns_to_centre_when_released() -> void:
	var spec := _fixture()

	var turned := _hold(spec, {"left": true}, 2.0)
	var released := _hold(spec, {}, 2.0, turned)

	assert_almost_eq(turned["steering_rad"], KeyboardDrive.MAX_STEERING_RAD, 1e-6)
	assert_eq(released["steering_rad"], 0.0)


func test_right_steers_right() -> void:
	var drive := _hold(_fixture(), {"right": true}, 0.1)

	assert_almost_eq(drive["steering_rad"], -KeyboardDrive.STEERING_RATE_RAD_S * 0.1, 1e-4)


func test_steers_less_at_speed() -> void:
	var fast := {"speed_m_s": KeyboardDrive.STEERING_FADE_SPEED_M_S, "steering_rad": 0.0}

	var drive := _hold(_fixture(), {"left": true}, 2.0, fast)

	assert_true(drive["steering_rad"] < KeyboardDrive.MAX_STEERING_RAD * 0.5, str(drive))


func test_keeps_enough_lock_at_speed_to_steer_into_a_slide() -> void:
	var fast := {"speed_m_s": 25.0, "steering_rad": 0.0}

	var drive := _hold(_fixture(), {"right": true}, 1.0, fast)

	# A slide of 17 degrees is caught by steering about as much the other way.
	assert_true(drive["steering_rad"] < -0.3, str(drive))


func test_the_driver_follows_the_vehicles_real_speed_after_a_crash() -> void:
	var spec := _fixture()
	var stopped_by_a_wall := {"speed_m_s": 0.0, "steering_rad": 0.0}

	var drive := KeyboardDrive.next(stopped_by_a_wall, {"up": true}, STEP_S, spec)

	var expected_m_s2 := Powertrain.full_throttle_acceleration_m_s2(spec, 0.0)
	assert_almost_eq(drive["speed_m_s"], expected_m_s2 * STEP_S, 1e-6)


func _hold(spec: VehicleSpec, keys: Dictionary, seconds: float, start := STOPPED) -> Dictionary:
	var drive: Dictionary = start
	for step in roundi(seconds / STEP_S):
		drive = KeyboardDrive.next(drive, keys, STEP_S, spec)
	return drive


func _fixture() -> VehicleSpec:
	return VehicleSpec.parse(PackFixtures.vehicle_manifest("small_car"), "")["vehicle"]


func _ovcs1(gear: int) -> VehicleSpec:
	## OVCS1 as its pack describes it: 1260 kg, 48 % on the front axle, eco tyres, a Nissan
	## Leaf motor through the Polo's five-speed gearbox.
	var manifest := PackFixtures.vehicle_manifest("ovcs1")
	var vehicle: Dictionary = manifest["vehicle"]
	vehicle["wheel_radius_m"] = 0.296
	vehicle["dynamics"]["mass_kg"] = 1260.0
	vehicle["dynamics"]["centre_of_gravity_x_m"] = -1.3 + 0.48 * 2.5
	vehicle["dynamics"]["friction"] = 0.9
	vehicle["powertrain"] = {
		"motor": {"max_power_w": 80000.0, "max_torque_n_m": 254.0, "max_rpm": 10500.0},
		"gear_ratios": [3.300, 1.944, 1.308, 0.971, 0.756],
		"final_drive_ratio": 3.389,
		"gear": gear,
		"driveline_efficiency": 0.9,
		"rolling_resistance_coefficient": 0.011,
		"drag_area_m2": 0.67,
	}
	return VehicleSpec.parse(manifest, "")["vehicle"]
