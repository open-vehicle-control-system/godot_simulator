extends TestCase
## What the cockpit's instruments show for the vehicle's motion.

const DIAL: Array[Vector2] = [Vector2(0.0, 0.0), Vector2(10.0, 15.0), Vector2(110.0, 135.0)]


func test_speedometer_needle_follows_the_dial_between_its_marks() -> void:
	var cases := {
		0.0: 0.0,
		5.0: 7.5,
		10.0: 15.0,
		60.0: 75.0,
		110.0: 135.0,
	}
	for speed_km_h in cases:
		assert_almost_eq(
			InstrumentScales.dial_angle_deg(DIAL, speed_km_h),
			cases[speed_km_h],
			1e-4,
			"%s km/h" % speed_km_h
		)


func test_speedometer_needle_stops_at_the_ends_of_the_dial() -> void:
	assert_almost_eq(InstrumentScales.dial_angle_deg(DIAL, 300.0), 135.0, 1e-4)
	assert_almost_eq(InstrumentScales.dial_angle_deg(DIAL, -5.0), 0.0, 1e-4)


func test_motor_turns_at_the_wheels_speed_times_the_gear_ratio() -> void:
	# [speed m/s, wheel radius m, motor to wheel ratio, motor rpm]
	var cases := [
		[0.0, 0.3, 8.0, 0.0],
		[TAU * 0.3, 0.3, 1.0, 60.0],
		[TAU * 0.3, 0.3, 8.0, 480.0],
		[-TAU * 0.3, 0.3, 8.0, 480.0],
		[10.0, 0.25, 2.0, 10.0 / (TAU * 0.25) * 60.0 * 2.0],
	]
	for case in cases:
		assert_almost_eq(
			InstrumentScales.motor_rpm(case[0], case[1], case[2]), case[3], 1e-3, str(case)
		)


func test_rev_counter_needle_turns_with_the_rpm_up_to_its_last_mark() -> void:
	# [rpm, degrees per rpm, last mark rpm, needle degrees]
	var cases := [
		[0.0, 0.05, 6000.0, 0.0],
		[3000.0, 0.05, 6000.0, 150.0],
		[6000.0, 0.05, 6000.0, 300.0],
		[9000.0, 0.05, 6000.0, 300.0],
	]
	for case in cases:
		assert_almost_eq(
			InstrumentScales.rev_counter_angle_deg(case[0], case[1], case[2]),
			case[3],
			1e-4,
			str(case)
		)


func test_steering_wheel_turns_by_the_steering_ratio_up_to_its_lock() -> void:
	# [front wheels rad, steering ratio, lock deg, steering wheel deg]
	var cases := [
		[0.0, 16.0, 500.0, 0.0],
		[deg_to_rad(10.0), 16.0, 500.0, 160.0],
		[deg_to_rad(-10.0), 16.0, 500.0, -160.0],
		[deg_to_rad(40.0), 16.0, 500.0, 500.0],
		[deg_to_rad(-40.0), 16.0, 500.0, -500.0],
	]
	for case in cases:
		assert_almost_eq(
			InstrumentScales.steering_wheel_angle_deg(case[0], case[1], case[2]),
			case[3],
			1e-3,
			str(case)
		)


func test_a_part_turns_about_its_axis_from_where_it_rests() -> void:
	var rest := Basis(Vector3.UP, 0.4)

	var turned := InstrumentScales.turned(rest, Vector3.BACK, 90.0)

	# Right-handed about +Z: what pointed along +X points along +Y.
	assert_almost_eq(turned.x, Basis(Vector3.BACK, PI / 2.0) * rest.x, 1e-5)
	assert_almost_eq(
		InstrumentScales.turned(Basis.IDENTITY, Vector3.BACK, 90.0).x, Vector3.UP, 1e-5
	)
