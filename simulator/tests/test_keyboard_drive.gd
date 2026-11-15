extends TestCase
## Driving with the arrow keys under --keyboard: drive and brake torques and steering from the
## keys held, the drive from the vehicle's powertrain.

const STEP_S := 1.0 / 60.0


func test_up_gives_the_motors_full_torque_through_the_gear() -> void:
	var spec := _fixture()

	var actuation := _keys({"up": true}, 0.0, 0.0, spec)

	assert_almost_eq(actuation.drive_torque_n_m, Powertrain.wheel_torque_n_m(spec, 1, 0.0), 1e-6)
	assert_eq(actuation.brake_torque_n_m, 0.0)
	assert_almost_eq(
		actuation.driveline_inertia_kg_m2, Powertrain.driveline_inertia_kg_m2(spec, 1), 1e-9
	)


func test_up_gives_nothing_past_the_motors_rpm_limit() -> void:
	var spec := _fixture()
	# 10,000 rpm through 8: the wheels at 131 rad/s.
	var actuation := _keys({"up": true}, 39.0, 131.0, spec)

	assert_eq(actuation.drive_torque_n_m, 0.0)


func test_the_gear_follows_the_driven_wheels_which_may_spin() -> void:
	var spec := _ovcs1(PowertrainSpec.AUTOMATIC)
	var standing_still := 0.0
	# The wheels spinning past first gear's shift point, the vehicle standing still.
	var spinning_rad_s := 105.0

	var actuation := _keys({"up": true}, standing_still, spinning_rad_s, spec)

	assert_true(
		actuation.driveline_inertia_kg_m2 < Powertrain.driveline_inertia_kg_m2(spec, 1),
		"shifted up from first"
	)


func test_down_brakes_then_reverses_once_stopped() -> void:
	var spec := _fixture()

	var braking := _keys({"down": true}, 10.0, 33.0, spec)
	var reversing := _keys({"down": true}, 0.0, 0.0, spec)
	var fast_enough := _keys(
		{"down": true}, -KeyboardDrive.MAX_REVERSE_SPEED_M_S - 0.1, -14.0, spec
	)

	assert_almost_eq(
		braking.brake_torque_n_m,
		KeyboardDrive.BRAKING_G * spec.mass_kg * Vehicle.GRAVITY_M_S2 * spec.wheel_radius_m,
		1e-6
	)
	assert_eq(braking.drive_torque_n_m, 0.0)
	assert_true(reversing.drive_torque_n_m < 0.0, "reverses")
	assert_eq(fast_enough.drive_torque_n_m, 0.0, "no faster than its reverse speed")


func test_up_brakes_a_reversing_vehicle() -> void:
	var actuation := _keys({"up": true}, -3.0, -10.0, _fixture())

	assert_true(actuation.brake_torque_n_m > 0.0)
	assert_eq(actuation.drive_torque_n_m, 0.0)


func test_coasts_with_no_key_and_holds_once_stopped() -> void:
	var spec := _fixture()

	var coasting := _keys({}, 20.0, 66.0, spec)
	var stopped := _keys({}, 0.1, 0.3, spec)

	assert_eq(coasting.drive_torque_n_m, 0.0)
	assert_eq(coasting.brake_torque_n_m, 0.0)
	assert_true(stopped.brake_torque_n_m > 0.0, "held")


func test_left_steers_left_and_returns_to_centre_when_released() -> void:
	var turned := _steer({"left": true}, 2.0, 0.0, 0.0)
	var released := _steer({}, 2.0, 0.0, turned)

	assert_almost_eq(turned, KeyboardDrive.MAX_STEERING_RAD, 1e-6)
	assert_eq(released, 0.0)


func test_right_steers_right() -> void:
	var steering_rad := _steer({"right": true}, 0.1, 0.0, 0.0)

	assert_almost_eq(steering_rad, -KeyboardDrive.STEERING_RATE_RAD_S * 0.1, 1e-4)


func test_steers_less_at_speed() -> void:
	var steering_rad := _steer({"left": true}, 2.0, KeyboardDrive.STEERING_FADE_SPEED_M_S, 0.0)

	assert_true(steering_rad < KeyboardDrive.MAX_STEERING_RAD * 0.5, str(steering_rad))


func test_keeps_enough_lock_at_speed_to_steer_into_a_slide() -> void:
	# A slide of 17 degrees is caught by steering about as much the other way.
	assert_true(_steer({"right": true}, 1.0, 25.0, 0.0) < -0.3)


func test_ovcs1_pulls_away_harder_in_first_than_in_third() -> void:
	var first := await _speed_after(_ovcs1(1), 3.0)
	var third := await _speed_after(_ovcs1(3), 3.0)

	assert_true(first > third + 1.0, "first %.2f m/s, third %.2f m/s" % [first, third])


func _speed_after(spec: VehicleSpec, seconds: float) -> float:
	## How fast `spec` goes after `seconds` of full throttle from standstill.
	var vehicle := await VehicleFixtures.on_flat_ground(self, spec)
	var steering_rad := 0.0
	for step in roundi(seconds / STEP_S):
		vehicle.actuate(
			_keys({"up": true}, vehicle.speed_m_s, vehicle.driven_wheel_speed_rad_s(), spec)
		)
		await wait_physics_frames(1)
	var speed_m_s := vehicle.speed_m_s
	vehicle.queue_free()
	await wait_physics_frames(1)
	return speed_m_s


static func _keys(
	keys: Dictionary, speed_m_s: float, wheel_rad_s: float, spec: VehicleSpec
) -> Actuation:
	return KeyboardDrive.next(0.0, speed_m_s, wheel_rad_s, keys, STEP_S, spec)


static func _steer(keys: Dictionary, seconds: float, speed_m_s: float, start_rad: float) -> float:
	var spec := _fixture()
	var steering_rad := start_rad
	for step in roundi(seconds / STEP_S):
		steering_rad = (
			KeyboardDrive.next(steering_rad, speed_m_s, 0.0, keys, STEP_S, spec).steering_rad
		)
	return steering_rad


static func _fixture() -> VehicleSpec:
	return VehicleSpec.parse(PackFixtures.vehicle_manifest("small_car"), "")["vehicle"]


static func _ovcs1(gear: int) -> VehicleSpec:
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
		"gear": "automatic" if gear == PowertrainSpec.AUTOMATIC else gear,
		"driveline_efficiency": 0.9,
		"rolling_resistance_coefficient": 0.011,
		"drag_area_m2": 0.67,
	}
	return VehicleSpec.parse(manifest, "")["vehicle"]
