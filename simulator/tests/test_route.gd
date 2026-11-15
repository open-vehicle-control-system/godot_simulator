extends TestCase
## A track's centre line and the driving that follows it.

const RADIUS_M := 50.0


func test_a_closed_circle_measures_its_length_and_curvature() -> void:
	var route := _circle(RADIUS_M, 200)

	assert_almost_eq(route.length_m, TAU * RADIUS_M, 0.1)
	for along_m in [0.0, 80.0, 250.0]:
		assert_almost_eq(route.curvature_at(along_m), 1.0 / RADIUS_M, 0.001, "turns left")


func test_finds_how_far_along_a_point_beside_it_is() -> void:
	var route := _circle(RADIUS_M, 200)
	var quarter := route.point_at(TAU * RADIUS_M / 4.0)
	var beside := quarter + (quarter - Vector3(RADIUS_M, 0.0, 0.0)).normalized()

	assert_almost_eq(route.nearest_m(beside), TAU * RADIUS_M / 4.0, 0.2)
	assert_almost_eq(route.nearest_m(beside, TAU * RADIUS_M / 4.0 - 5.0), TAU * RADIUS_M / 4.0, 0.2)
	assert_almost_eq(route.offset_m(beside, TAU * RADIUS_M / 4.0), 1.0, 0.01)


func test_a_closed_route_wraps_and_an_open_one_ends() -> void:
	var circle := _circle(RADIUS_M, 200)
	var line := Route.of(PackedVector3Array([Vector3.ZERO, Vector3(0.0, 0.0, 100.0)]), false)

	assert_almost_eq(circle.point_at(circle.length_m + 10.0), circle.point_at(10.0), 1e-4)
	assert_almost_eq(line.point_at(150.0), Vector3(0.0, 0.0, 100.0), 1e-6)
	assert_almost_eq(line.curvature_at(50.0), 0.0, 1e-9)


func test_steers_towards_the_line_ahead() -> void:
	var line := Route.of(PackedVector3Array([Vector3.ZERO, Vector3(0.0, 0.0, 500.0)]), false)

	var on_it := RouteFollowing.steering_rad(line, Vector3.ZERO, Basis.IDENTITY, 0.0, 10.0, 2.5)
	var right_of_it := RouteFollowing.steering_rad(
		line, Vector3(-2.0, 0.0, 0.0), Basis.IDENTITY, 0.0, 10.0, 2.5
	)

	assert_almost_eq(on_it, 0.0, 1e-9)
	assert_true(right_of_it > 0.0, "left, back onto it: %f" % right_of_it)


func test_slows_for_corners_and_for_the_end_of_an_open_route() -> void:
	var tight := _circle(20.0, 120)
	var line := Route.of(PackedVector3Array([Vector3.ZERO, Vector3(0.0, 0.0, 500.0)]), false)
	var grip_m_s2 := 8.0

	var on_the_circle := RouteFollowing.speed_m_s(tight, 10.0, 30.0, grip_m_s2)
	var on_the_straight := RouteFollowing.speed_m_s(line, 0.0, 30.0, grip_m_s2)
	var at_the_end := RouteFollowing.speed_m_s(line, 500.0, 30.0, grip_m_s2)

	var corner_m_s := sqrt(RouteFollowing.GRIP_SHARE * grip_m_s2 * 20.0)
	assert_almost_eq(on_the_circle, corner_m_s, 0.3)
	assert_eq(on_the_straight, 30.0)
	assert_almost_eq(at_the_end, 0.0, 1e-6)


func test_reads_a_route_from_its_pack() -> void:
	var found := _track_with_route(
		{"closed": true, "points_m": [[0, 0, 1], [10, 0, 1], [10, 10, 2]]}
	)

	var route: Route = found["track"].route
	assert_eq(route.points.size(), 3)
	assert_true(route.closed)
	assert_almost_eq(route.points[1], Vector3(0.0, 1.0, 10.0), 1e-6, "in Godot's frame")


func test_refuses_a_route_of_fewer_than_two_points() -> void:
	var found := _track_with_route({"closed": false, "points_m": [[0, 0, 0]]})

	assert_eq(found, {"error": "flat: route.json: points_m is out of range"})


func test_follow_route_gives_the_speed_to_drive_the_centre_line_at() -> void:
	var options: SimulatorOptions = (
		SimulatorOptions.parse(PackedStringArray(["--follow-route=54"]))["options"]
	)

	assert_true(options.follow_route_given)
	assert_almost_eq(options.follow_route_speed_m_s, 15.0, 1e-6)


func test_follow_route_is_refused_with_another_way_of_driving_or_without_a_speed() -> void:
	var refused := "--follow-route drives the vehicle: not with "
	refused += "--keyboard, --link, --hold or --drive-log"
	var cases := {
		"--keyboard": refused,
		"--link=localhost": refused,
		"--hold=30,0": refused,
		"--drive-log=/a.csv": refused,
	}
	for argument in cases:
		var parsed := SimulatorOptions.parse(PackedStringArray(["--follow-route=50", argument]))
		assert_eq(parsed, {"error": cases[argument]}, argument)
	for speed in ["fast", "0", "-10"]:
		assert_eq(
			SimulatorOptions.parse(PackedStringArray(["--follow-route=" + speed])),
			{"error": "--follow-route is a positive speed in km/h"},
			speed
		)


func _track_with_route(route: Dictionary) -> Dictionary:
	var directory := PackFixtures.fresh_directory("route")
	var manifest := PackFixtures.track_manifest("flat")
	manifest["track"]["route"] = "route.json"
	var pack := PackFixtures.write_pack(directory, manifest)
	PackFixtures.write_flat_world(pack, 100.0)
	FileAccess.open(pack.path_join("route.json"), FileAccess.WRITE).store_string(
		JSON.stringify(route)
	)
	return PackLibrary.scan([directory]).load_track("flat")


static func _circle(radius_m: float, count: int) -> Route:
	## A circle starting at the origin heading +Z and turning left, towards +X.
	var points := PackedVector3Array()
	for index in count:
		var angle := TAU * index / count
		points.append(Vector3(radius_m * (1.0 - cos(angle)), 0.0, radius_m * sin(angle)))
	return Route.of(points, true)
