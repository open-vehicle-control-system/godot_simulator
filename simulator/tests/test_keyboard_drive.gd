extends TestCase
## Driving with the arrow keys under --keyboard: speed and steering from the keys held.

const STEP_S := 1.0 / 60.0


func test_up_accelerates_forward() -> void:
	var drive := _hold({"up": true}, 2.0)

	assert_almost_eq(drive["speed_m_s"], KeyboardDrive.ACCELERATION_M_S2 * 2.0, 0.01)


func test_never_goes_faster_than_the_top_speed() -> void:
	var drive := _hold({"up": true}, 60.0)

	assert_almost_eq(drive["speed_m_s"], KeyboardDrive.MAX_SPEED_M_S, 1e-6)


func test_down_brakes_then_reverses_once_stopped() -> void:
	var moving := {"speed_m_s": 10.0, "steering_rad": 0.0}

	var braking := KeyboardDrive.next(moving, {"down": true}, STEP_S)
	var reversing := _hold({"down": true}, 4.0, {"speed_m_s": 0.0, "steering_rad": 0.0})

	assert_almost_eq(braking["speed_m_s"], 10.0 - KeyboardDrive.BRAKING_M_S2 * STEP_S, 1e-5)
	assert_almost_eq(reversing["speed_m_s"], -KeyboardDrive.MAX_REVERSE_SPEED_M_S, 1e-6)


func test_up_brakes_a_reversing_vehicle() -> void:
	var reversing := {"speed_m_s": -3.0, "steering_rad": 0.0}

	var drive := KeyboardDrive.next(reversing, {"up": true}, STEP_S)

	assert_almost_eq(drive["speed_m_s"], -3.0 + KeyboardDrive.BRAKING_M_S2 * STEP_S, 1e-5)


func test_coasts_down_to_a_stop_with_no_key() -> void:
	var drive := _hold({}, 30.0, {"speed_m_s": 5.0, "steering_rad": 0.0})

	assert_eq(drive["speed_m_s"], 0.0)


func test_left_steers_left_and_returns_to_centre_when_released() -> void:
	var turned := _hold({"left": true}, 2.0)
	var released := _hold({}, 2.0, turned)

	assert_almost_eq(turned["steering_rad"], KeyboardDrive.MAX_STEERING_RAD, 1e-6)
	assert_eq(released["steering_rad"], 0.0)


func test_right_steers_right() -> void:
	var drive := _hold({"right": true}, 0.1)

	assert_almost_eq(drive["steering_rad"], -KeyboardDrive.STEERING_RATE_RAD_S * 0.1, 1e-4)


func test_steers_less_at_speed() -> void:
	var fast := {"speed_m_s": KeyboardDrive.MAX_SPEED_M_S, "steering_rad": 0.0}

	var drive := _hold({"left": true, "up": true}, 2.0, fast)

	assert_true(drive["steering_rad"] < KeyboardDrive.MAX_STEERING_RAD * 0.5, str(drive))


func _hold(
	keys: Dictionary, seconds: float, start := {"speed_m_s": 0.0, "steering_rad": 0.0}
) -> Dictionary:
	var drive: Dictionary = start
	for step in roundi(seconds / STEP_S):
		drive = KeyboardDrive.next(drive, keys, STEP_S)
	return drive


func test_the_driver_follows_the_vehicles_real_speed_after_a_crash() -> void:
	var stopped_by_a_wall := {"speed_m_s": 0.0, "steering_rad": 0.0}

	var drive := KeyboardDrive.next(stopped_by_a_wall, {"up": true}, STEP_S)

	assert_almost_eq(drive["speed_m_s"], KeyboardDrive.ACCELERATION_M_S2 * STEP_S, 1e-6)
