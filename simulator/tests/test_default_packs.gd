extends TestCase
## The packs the simulator bundles: started without options, it drives the default vehicle
## on the default track.

const MAIN_SCENE := "res://main.tscn"
const HOLD_KM_H := 30.0
const DRIVEN_S := 3.0
const MAX_CLIMB_M := 2.0
const ROUTE_KM_H := 60.0
const ROUTE_S := 45


func test_both_default_packs_load() -> void:
	var library := PackLibrary.scan([ProjectSettings.globalize_path("res://default_packs")])

	assert_eq(library.errors, [] as Array[String])
	var track := library.load_track("default_track")
	var vehicle := library.load_vehicle("default_car")
	assert_true(track.has("track"), str(track.get("error", "")))
	assert_true(vehicle.has("vehicle"), str(vehicle.get("error", "")))


func test_the_default_car_reaches_100_km_h_in_about_12_s_at_full_throttle() -> void:
	var library := PackLibrary.scan([ProjectSettings.globalize_path("res://default_packs")])
	var spec: VehicleSpec = library.load_vehicle("default_car")["vehicle"]
	var vehicle := await VehicleFixtures.on_flat_ground(self, spec)
	var step_s := 1.0 / Engine.physics_ticks_per_second
	var elapsed_s := 0.0

	while vehicle.speed_m_s < 100.0 / 3.6 and elapsed_s < 30.0:
		vehicle.actuate(
			KeyboardDrive.next(
				0.0,
				vehicle.speed_m_s,
				vehicle.driven_wheel_speed_rad_s(),
				{"up": true},
				step_s,
				spec
			)
		)
		await wait_physics_frames(1)
		elapsed_s += step_s

	assert_true(elapsed_s > 11.0 and elapsed_s < 14.0, "0-100 km/h in %.1f s" % elapsed_s)


func test_starts_without_options_and_drives_on_the_default_track() -> void:
	var simulator: Node3D = load(MAIN_SCENE).instantiate()
	simulator.arguments = PackedStringArray(["--hold=%s,0" % HOLD_KM_H])

	add_child(simulator)
	var vehicle: Vehicle = simulator.get_node_or_null("Vehicle")
	assert_true(vehicle != null, "the simulator built its world")
	if vehicle == null:
		simulator.queue_free()
		return
	var start := vehicle.global_position
	await wait_physics_frames(roundi(DRIVEN_S * Engine.physics_ticks_per_second))

	var driven_m := (vehicle.global_position - start).length()
	assert_almost_eq(driven_m, HOLD_KM_H / 3.6 * DRIVEN_S, 3.0, "driven %s m" % driven_m)
	# The road climbs and falls gently: the vehicle rides it, neither sinks nor flies.
	assert_almost_eq(vehicle.global_position.y, start.y, MAX_CLIMB_M, "rides the road")
	simulator.queue_free()


func test_follows_the_default_tracks_centre_line_within_a_metre() -> void:
	var simulator: Node3D = load(MAIN_SCENE).instantiate()
	simulator.arguments = PackedStringArray(["--follow-route=%s" % ROUTE_KM_H])
	add_child(simulator)
	var vehicle: Vehicle = simulator.get_node("Vehicle")
	var driver: RouteDriver = simulator.get_node("RouteDriver")
	var route := Route.of(PackedVector3Array(), true)
	var library := PackLibrary.scan([ProjectSettings.globalize_path("res://default_packs")])
	route = library.load_track("default_track")["track"].route
	var furthest_off_m := 0.0
	var start_m := -1.0

	for step in ROUTE_S * Engine.physics_ticks_per_second:
		await wait_physics_frames(1)
		var rear_axle := vehicle.global_transform * Vector3(0.0, 0.0, vehicle.spec.rear_axle_z)
		var along_m := route.nearest_m(rear_axle)
		if start_m < 0.0:
			start_m = along_m
		# Settled at speed, off the start.
		if step > 5 * Engine.physics_ticks_per_second:
			furthest_off_m = maxf(furthest_off_m, route.offset_m(rear_axle, along_m))

	var driven_m := fposmod(driver.along_m() - start_m, route.length_m)
	assert_true(driven_m > 400.0, "drove %.0f m of the route" % driven_m)
	assert_true(furthest_off_m < 1.0, "at most %.2f m off the centre line" % furthest_off_m)
	simulator.queue_free()
