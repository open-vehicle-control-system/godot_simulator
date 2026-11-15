extends TestCase
## The dynamic bicycle model: tyres that slip, so a fast corner can swing the tail out, slide and
## spin, while slow driving follows the kinematic path.

const STEP_S := 1.0 / 60.0
const WHEELBASE_M := 2.5
const GRIP_M_S2 := 7.8
const CORNER_SPEED_M_S := 22.0
## At CORNER_SPEED_M_S this steering corners at about two thirds of the grip.
const CORNER_STEERING_RAD := 0.04


func test_slow_gentle_turns_follow_the_kinematic_path() -> void:
	var cases := {
		"walking pace, full lock": [2.0, 0.5],
		"town, half lock": [5.0, 0.25],
		"gentle bend": [5.0, 0.04],
		"reversing": [-3.0, 0.3],
	}
	for case in cases:
		var speed_m_s: float = cases[case][0]
		var steering_rad: float = cases[case][1]

		var motion := _drive(DynamicBicycle.rolling(0.0, speed_m_s), speed_m_s, steering_rad, 10.0)

		var kinematic_rad_s := speed_m_s * tan(steering_rad) / WHEELBASE_M
		var yaw_rate_rad_s: float = motion["yaw_rate_rad_s"]
		assert_almost_eq(yaw_rate_rad_s, kinematic_rad_s, absf(kinematic_rad_s) * 0.04, case)


func test_parking_speeds_turn_exactly_as_the_kinematic_model() -> void:
	var motion := _drive(DynamicBicycle.rolling(0.0, 0.5), 0.5, 0.5, 2.0)

	assert_almost_eq(motion["yaw_rate_rad_s"], 0.5 * tan(0.5) / WHEELBASE_M, 1e-9)


func test_cornering_never_exceeds_the_grip() -> void:
	for steering_rad in [0.02, 0.04, 0.06, 0.1, 0.2, 0.5]:
		var motion := DynamicBicycle.rolling(0.0, 25.0)
		var hardest_m_s2 := 0.0
		for step in roundi(8.0 / STEP_S):
			var steering_now_rad := minf(steering_rad, step * STEP_S * 1.2)
			motion = DynamicBicycle.advance(motion, _spec(), 25.0, steering_now_rad, STEP_S)
			hardest_m_s2 = maxf(hardest_m_s2, absf(motion["lateral_acceleration_m_s2"]))

		assert_true(
			hardest_m_s2 <= GRIP_M_S2 + 1e-3, "%.2f rad: %.3f" % [steering_rad, hardest_m_s2]
		)


func test_cornering_at_the_limit_reaches_most_of_the_grip() -> void:
	var motion := _drive(DynamicBicycle.rolling(0.0, 25.0), 25.0, 0.06, 6.0)

	assert_true(motion["lateral_acceleration_m_s2"] > GRIP_M_S2 * 0.85, str(motion))


func test_braking_into_a_fast_corner_swings_the_tail_out() -> void:
	var cases := {"trail braking at 0.4 g": 4.0, "braking at 0.6 g": 6.0}
	for case in cases:
		var deceleration_m_s2: float = cases[case]
		var cornering := _corner()
		var turned_in_sideslip_rad := _sideslip_rad(cornering)

		var braked := _brake(cornering, deceleration_m_s2, 0.75, CORNER_STEERING_RAD)

		var speed_m_s: float = braked["speed_m_s"]
		var path_rad_s := speed_m_s * tan(CORNER_STEERING_RAD) / WHEELBASE_M
		assert_true(
			_sideslip_rad(braked) < turned_in_sideslip_rad - deg_to_rad(4.0),
			"%s: sideslip %.1f deg" % [case, rad_to_deg(_sideslip_rad(braked))]
		)
		assert_true(
			braked["yaw_rate_rad_s"] > path_rad_s * 1.3,
			"%s: yaw rate %.2f, path %.2f" % [case, braked["yaw_rate_rad_s"], path_rad_s]
		)


func test_a_steady_corner_keeps_its_sideslip_small() -> void:
	var cornering := _corner()

	assert_true(absf(_sideslip_rad(cornering)) < deg_to_rad(3.0), str(cornering))


func test_braking_hard_through_a_fast_corner_spins() -> void:
	var braked := _brake(_corner(), 6.0, 2.0, CORNER_STEERING_RAD)

	assert_true(
		_sideslip_rad(braked) < -deg_to_rad(45.0),
		"sideslip %.1f deg" % rad_to_deg(_sideslip_rad(braked))
	)


func test_steering_into_the_slide_catches_it() -> void:
	var sliding := _brake(_corner(), 4.0, 0.75, CORNER_STEERING_RAD)
	var held := sliding
	var caught := sliding

	for step in roundi(1.5 / STEP_S):
		held = DynamicBicycle.advance(held, _spec(), held["speed_m_s"], CORNER_STEERING_RAD, STEP_S)
		var into_the_slide_rad := clampf(_sideslip_rad(caught), -0.5, 0.5)
		caught = DynamicBicycle.advance(
			caught, _spec(), caught["speed_m_s"], into_the_slide_rad, STEP_S
		)

	assert_true(absf(_sideslip_rad(caught)) < deg_to_rad(1.0), "caught: %s" % caught)
	assert_true(absf(caught["yaw_rate_rad_s"]) < 0.05, "caught: %s" % caught)
	assert_true(absf(_sideslip_rad(held)) > deg_to_rad(5.0), "held: %s" % held)


func test_standing_still_stays_still_whatever_the_steering() -> void:
	var motion := DynamicBicycle.rolling(0.3, 0.0)

	for step in 180:
		motion = DynamicBicycle.advance(motion, _spec(), 0.0, 0.5 * sin(step * 0.1), STEP_S)

	assert_almost_eq(motion["centre"], Vector3.ZERO, 1e-9)
	assert_almost_eq(motion["yaw_rad"], 0.3, 1e-9)
	assert_eq(motion["lateral_velocity_m_s"], 0.0)
	assert_eq(motion["yaw_rate_rad_s"], 0.0)


func test_wild_steering_at_top_speed_stays_bounded() -> void:
	var motion := DynamicBicycle.rolling(0.0, 50.0)

	for step in roundi(30.0 / STEP_S):
		var lock_rad := 0.5 if (step / 60) % 2 == 0 else -0.5
		motion = DynamicBicycle.advance(motion, _spec(), 50.0, lock_rad, STEP_S)
		var lateral_m_s: float = motion["lateral_velocity_m_s"]
		var yaw_rate_rad_s: float = motion["yaw_rate_rad_s"]
		if absf(lateral_m_s) > 50.0 or absf(yaw_rate_rad_s) > 4.0:
			fail("unbounded at step %d: %s" % [step, motion])
			return


func test_moves_along_its_heading_plus_its_lateral_velocity() -> void:
	var motion := DynamicBicycle.rolling(0.0, 10.0)
	motion["lateral_velocity_m_s"] = 1.0

	var moved := DynamicBicycle.advance(motion, _spec(), 10.0, 0.0, 0.01)

	# Heading +Z, lateral velocity towards +X (left).
	assert_almost_eq(moved["centre"].z, 0.1, 1e-3)
	assert_true(moved["centre"].x > 0.009, str(moved["centre"]))


func test_reports_the_longitudinal_acceleration_of_the_speed_change() -> void:
	var motion := DynamicBicycle.advance(DynamicBicycle.rolling(0.0, 10.0), _spec(), 9.9, 0.0, 0.1)

	assert_almost_eq(motion["longitudinal_acceleration_m_s2"], -1.0, 1e-6)
	assert_almost_eq(motion["speed_m_s"], 9.9, 1e-9)


func test_a_steady_turns_lateral_acceleration_is_speed_times_yaw_rate() -> void:
	var motion := _drive(DynamicBicycle.rolling(0.0, 10.0), 10.0, 0.05, 6.0)

	assert_almost_eq(
		motion["lateral_acceleration_m_s2"], 10.0 * float(motion["yaw_rate_rad_s"]), 0.02
	)
	assert_almost_eq(motion["yaw_acceleration_rad_s2"], 0.0, 0.01)


func _spec() -> VehicleSpec:
	## A small car: 48 % of its weight on the front axle, front-wheel drive.
	var spec := VehicleSpec.new()
	spec.front_axle_z = 1.2
	spec.rear_axle_z = -1.3
	spec.centre_of_gravity_z = -0.1
	spec.centre_of_gravity_height_m = 0.53
	spec.mass_kg = 1230.0
	spec.yaw_inertia_kg_m2 = 1900.0
	spec.front_cornering_stiffness_n_per_rad = 80000.0
	spec.rear_cornering_stiffness_n_per_rad = 130000.0
	spec.max_lateral_acceleration_m_s2 = GRIP_M_S2
	spec.driven_axle = "front"
	return spec


func _drive(
	motion: Dictionary, speed_m_s: float, steering_rad: float, seconds: float
) -> Dictionary:
	for step in roundi(seconds / STEP_S):
		motion = DynamicBicycle.advance(motion, _spec(), speed_m_s, steering_rad, STEP_S)
	return motion


func _corner() -> Dictionary:
	## Settled into a fast left-hand corner.
	return _drive(
		DynamicBicycle.rolling(0.0, CORNER_SPEED_M_S), CORNER_SPEED_M_S, CORNER_STEERING_RAD, 4.0
	)


func _brake(
	motion: Dictionary, deceleration_m_s2: float, seconds: float, steering_rad: float
) -> Dictionary:
	for step in roundi(seconds / STEP_S):
		var speed_m_s: float = motion["speed_m_s"] - deceleration_m_s2 * STEP_S
		motion = DynamicBicycle.advance(motion, _spec(), speed_m_s, steering_rad, STEP_S)
	return motion


func _sideslip_rad(motion: Dictionary) -> float:
	## The angle from the heading to the velocity at the centre of gravity, positive left.
	return atan2(motion["lateral_velocity_m_s"], absf(motion["speed_m_s"]))
