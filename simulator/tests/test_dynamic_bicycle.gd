extends TestCase
## The dynamic bicycle model: tyres that slip, held to what standard tests measure on a
## production front-wheel drive sedan (ISO 4138 steady-state circular driving, ISO 7975 braking
## in a turn), while slow driving follows the kinematic path.

const STEP_S := 1.0 / 60.0
const GRAVITY_M_S2 := 9.81
const WHEELBASE_M := 2.915
const FRICTION := 1.0
const GRIP_M_S2 := FRICTION * GRAVITY_M_S2
## ISO 7975's turn: 60 km/h on a 50 m radius, about 0.57 g.
const TURN_RADIUS_M := 50.0
const TURN_SPEED_M_S := 60.0 / 3.6


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

		var motion := _drive(
			_spec(), DynamicBicycle.rolling(0.0, speed_m_s), speed_m_s, steering_rad, 10.0
		)

		var kinematic_rad_s := speed_m_s * tan(steering_rad) / WHEELBASE_M
		var yaw_rate_rad_s: float = motion["yaw_rate_rad_s"]
		assert_almost_eq(yaw_rate_rad_s, kinematic_rad_s, absf(kinematic_rad_s) * 0.04, case)


func test_parking_speeds_turn_exactly_as_the_kinematic_model() -> void:
	var motion := _drive(_spec(), DynamicBicycle.rolling(0.0, 0.5), 0.5, 0.5, 2.0)

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
	var motion := _drive(_spec(), DynamicBicycle.rolling(0.0, 25.0), 25.0, 0.1, 6.0)

	assert_true(motion["lateral_acceleration_m_s2"] > GRIP_M_S2 * 0.8, str(motion))


func test_understeers_by_one_to_four_degrees_per_g() -> void:
	# ISO 4138, constant radius: the steering a 50 m circle takes, from 0.1 g to 0.4 g.
	var gradient_deg_per_g := _understeer_gradient_deg_per_g(_spec())

	assert_true(
		gradient_deg_per_g > 1.0 and gradient_deg_per_g < 4.0, "%.2f deg/g" % gradient_deg_per_g
	)


func test_softer_rear_tyres_turn_understeer_into_oversteer() -> void:
	var spec := _spec()
	spec.rear_cornering_stiffness_n_per_rad *= 0.5

	var gradient_deg_per_g := _understeer_gradient_deg_per_g(spec)

	assert_true(gradient_deg_per_g < 0.0, "%.2f deg/g" % gradient_deg_per_g)


func test_braking_in_a_turn_tightens_the_line_a_little() -> void:
	# ISO 7975: settled at 60 km/h on 50 m, then braking with the steering held. The yaw rate
	# a second later, over the one that keeps the radius at that speed, and the sideslip.
	var cases := {"0.4 g": 0.4, "0.6 g": 0.6}
	for case in cases:
		var spec := _spec()

		var braked := _brake(
			spec, _turning(spec), cases[case] * GRAVITY_M_S2, 1.0, _turn_steering(spec)
		)

		var yaw_ratio := _yaw_ratio(braked["motion"])
		var message := (
			"%s: yaw ratio %.2f, sideslip up to %.1f deg"
			% [case, yaw_ratio, rad_to_deg(braked["most_sideslip_rad"])]
		)
		assert_true(yaw_ratio > 1.0 and yaw_ratio < 1.5, message)
		assert_true(braked["most_sideslip_rad"] < deg_to_rad(5.0), message)


func test_lifting_off_at_the_limit_tucks_in_without_a_slide() -> void:
	var spec := _spec()
	var speed_m_s := sqrt(0.8 * GRAVITY_M_S2 * TURN_RADIUS_M)
	var steering_rad := _steering_for_radius(spec, speed_m_s)
	var turning := _drive(
		spec, DynamicBicycle.rolling(0.0, speed_m_s), speed_m_s, steering_rad, 4.0
	)

	var lifted := _brake(spec, turning, 0.25 * GRAVITY_M_S2, 1.0, steering_rad)

	var yaw_ratio := _yaw_ratio(lifted["motion"])
	var message := (
		"yaw ratio %.2f, sideslip up to %.1f deg"
		% [yaw_ratio, rad_to_deg(lifted["most_sideslip_rad"])]
	)
	assert_true(yaw_ratio > 1.0 and yaw_ratio < 1.6, message)
	assert_true(lifted["most_sideslip_rad"] < deg_to_rad(5.0), message)


func test_braking_the_rear_beyond_its_load_slides_the_tail_out() -> void:
	var cases := {
		"the sedan's brakes": [0.7, 0.05, 0.0, 5.0],
		"rear-biased, without proportioning": [0.4, -1.0, 15.0, 180.0],
	}
	for case in cases:
		var spec := _spec()
		spec.brake_bias_front = cases[case][0]
		spec.rear_brake_margin = cases[case][1]

		var braked := _brake(spec, _turning(spec), 0.6 * GRAVITY_M_S2, 1.0, _turn_steering(spec))

		var most_deg := rad_to_deg(braked["most_sideslip_rad"])
		assert_true(
			most_deg >= cases[case][2] and most_deg < cases[case][3],
			"%s: sideslip up to %.1f deg" % [case, most_deg]
		)


func test_steering_into_the_slide_catches_it() -> void:
	var spec := _spec()
	spec.brake_bias_front = 0.4
	spec.rear_brake_margin = -1.0
	var steering_rad := _turn_steering(spec)
	var braked := _brake(spec, _turning(spec), 0.6 * GRAVITY_M_S2, 0.5, steering_rad)
	var sliding: Dictionary = braked["motion"]
	var caught := sliding

	for step in roundi(1.5 / STEP_S):
		var into_the_slide_rad := clampf(_sideslip_rad(caught), -0.5, 0.5)
		caught = DynamicBicycle.advance(
			caught, spec, caught["speed_m_s"], into_the_slide_rad, STEP_S
		)

	assert_true(absf(_sideslip_rad(sliding)) > deg_to_rad(5.0), "sliding: %s" % sliding)
	assert_true(absf(_sideslip_rad(caught)) < deg_to_rad(1.0), "caught: %s" % caught)
	assert_true(absf(caught["yaw_rate_rad_s"]) < 0.05, "caught: %s" % caught)


func test_a_steady_corner_keeps_its_sideslip_small() -> void:
	var turning := _turning(_spec())

	assert_true(absf(_sideslip_rad(turning)) < deg_to_rad(3.0), str(turning))


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
	var motion := _drive(_spec(), DynamicBicycle.rolling(0.0, 10.0), 10.0, 0.05, 6.0)

	assert_almost_eq(
		motion["lateral_acceleration_m_s2"], 10.0 * float(motion["yaw_rate_rad_s"]), 0.02
	)
	assert_almost_eq(motion["yaw_acceleration_rad_s2"], 0.0, 0.01)


func test_the_driven_axle_passes_on_its_grip_at_the_load_accelerating_leaves_on_it() -> void:
	# Without load sensitivity an axle holds friction times its load, and accelerating at a
	# moves m a h / L from the front axle to the rear one: F = mu (static load -+ F h / L).
	var weight_n := 1350.0 * GRAVITY_M_S2
	var transfer_per_n := 0.55 / WHEELBASE_M
	var cases := {
		"front": FRICTION * weight_n * 0.6 / (1.0 + FRICTION * transfer_per_n),
		"rear": FRICTION * weight_n * 0.4 / (1.0 - FRICTION * transfer_per_n),
		"all": FRICTION * weight_n,
	}
	for driven_axle in cases:
		var spec := _spec()
		spec.friction_load_sensitivity = 0.0
		spec.driven_axle = driven_axle

		var traction_n := DynamicBicycle.traction_limit_n(spec)

		assert_almost_eq(traction_n, cases[driven_axle], 1.0, driven_axle)


func test_load_sensitivity_lets_the_unloaded_front_axle_pass_on_a_little_more() -> void:
	var sensitive := _spec()
	var insensitive := _spec()
	insensitive.friction_load_sensitivity = 0.0

	var traction_n := DynamicBicycle.traction_limit_n(sensitive)

	var insensitive_n := DynamicBicycle.traction_limit_n(insensitive)
	assert_true(traction_n > insensitive_n, "%s > %s" % [traction_n, insensitive_n])
	assert_true(traction_n < insensitive_n * 1.1, "%s" % traction_n)


func _spec() -> VehicleSpec:
	## A mid-size front-wheel drive sedan: 1350 kg, 60 % of it on the front axle.
	var spec := VehicleSpec.new()
	spec.front_axle_z = WHEELBASE_M * 0.5
	spec.rear_axle_z = -WHEELBASE_M * 0.5
	spec.front_track_m = 1.63
	spec.rear_track_m = 1.63
	spec.mass_kg = 1350.0
	spec.centre_of_gravity_z = spec.rear_axle_z + 0.6 * WHEELBASE_M
	spec.centre_of_gravity_height_m = 0.55
	spec.yaw_inertia_kg_m2 = 2480.0
	spec.friction = FRICTION
	spec.max_lateral_acceleration_m_s2 = GRIP_M_S2
	spec.front_cornering_stiffness_n_per_rad = 99000.0
	spec.rear_cornering_stiffness_n_per_rad = 116500.0
	spec.cornering_stiffness_load_exponent = 0.7
	spec.friction_load_sensitivity = 0.25
	spec.tyre_shape = 1.3
	spec.tyre_curvature = -1.5
	spec.front_roll_stiffness_share = 0.75
	spec.brake_bias_front = 0.7
	spec.rear_brake_margin = 0.05
	spec.driven_axle = "front"
	return spec


func _drive(
	spec: VehicleSpec, motion: Dictionary, speed_m_s: float, steering_rad: float, seconds: float
) -> Dictionary:
	for step in roundi(seconds / STEP_S):
		motion = DynamicBicycle.advance(motion, spec, speed_m_s, steering_rad, STEP_S)
	return motion


func _steering_for_radius(spec: VehicleSpec, speed_m_s: float) -> float:
	## The steering that settles on TURN_RADIUS_M at `speed_m_s`.
	var steering_rad := WHEELBASE_M / TURN_RADIUS_M
	for attempt in 8:
		var settled := _drive(
			spec, DynamicBicycle.rolling(0.0, speed_m_s), speed_m_s, steering_rad, 4.0
		)
		var radius_m: float = speed_m_s / float(settled["yaw_rate_rad_s"])
		steering_rad += WHEELBASE_M / TURN_RADIUS_M - WHEELBASE_M / radius_m
	return steering_rad


func _understeer_gradient_deg_per_g(spec: VehicleSpec) -> float:
	var gentle_rad := _steering_for_radius(spec, sqrt(0.1 * GRAVITY_M_S2 * TURN_RADIUS_M))
	var brisk_rad := _steering_for_radius(spec, sqrt(0.4 * GRAVITY_M_S2 * TURN_RADIUS_M))
	return rad_to_deg(brisk_rad - gentle_rad) / 0.3


func _turn_steering(spec: VehicleSpec) -> float:
	return _steering_for_radius(spec, TURN_SPEED_M_S)


func _turning(spec: VehicleSpec) -> Dictionary:
	## Settled on ISO 7975's turn, to the left.
	return _drive(
		spec, DynamicBicycle.rolling(0.0, TURN_SPEED_M_S), TURN_SPEED_M_S, _turn_steering(spec), 4.0
	)


func _brake(
	spec: VehicleSpec,
	motion: Dictionary,
	deceleration_m_s2: float,
	seconds: float,
	steering_rad: float
) -> Dictionary:
	## `{"motion", "most_sideslip_rad"}` after slowing down at `deceleration_m_s2`.
	var most_sideslip_rad := 0.0
	for step in roundi(seconds / STEP_S):
		var speed_m_s := maxf(float(motion["speed_m_s"]) - deceleration_m_s2 * STEP_S, 1.0)
		motion = DynamicBicycle.advance(motion, spec, speed_m_s, steering_rad, STEP_S)
		most_sideslip_rad = maxf(most_sideslip_rad, absf(_sideslip_rad(motion)))
	return {"motion": motion, "most_sideslip_rad": most_sideslip_rad}


func _yaw_ratio(motion: Dictionary) -> float:
	## The yaw rate over the one that keeps TURN_RADIUS_M at the motion's speed.
	return float(motion["yaw_rate_rad_s"]) / (float(motion["speed_m_s"]) / TURN_RADIUS_M)


func _sideslip_rad(motion: Dictionary) -> float:
	## The angle from the heading to the velocity at the centre of gravity, positive left.
	return atan2(motion["lateral_velocity_m_s"], absf(motion["speed_m_s"]))
